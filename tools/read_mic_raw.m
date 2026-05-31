function [data, seq, info] = read_mic_raw(port, nframes, timeout_s)
%READ_MIC_RAW Read RAW1 frames from STM32 OTG USB CDC and plot 8-mic FFT.
%
%   [data, seq, info] = read_mic_raw("COM12", 1)
%   read_mic_raw("COM12", inf)        % realtime FFT for all 8 microphones
%
% Use the OTG USB CDC COM port, not the ST-LINK VCP status port.

    if nargin < 1 || isempty(port), port = "COM12"; end
    if nargin < 2 || isempty(nframes), nframes = 1; end
    if nargin < 3 || isempty(timeout_s), timeout_s = 20; end

    port = char(string(port));
    realtime = isinf(nframes);

    FS = 16000;
    NCH_EXPECTED = 8;
    FMT_INT32 = 0;
    HDR = 12;
    MAGIC = uint8('RAW1');

    fprintf('Opening %s for RAW1 mic frames...\n', port);
    fprintf('Available serial ports: %s\n', strjoin(string(serialportlist("available")), ", "));
    if realtime
        fprintf('Realtime FFT only. Press Ctrl+C to stop.\n');
    else
        fprintf('Waiting for %d frame(s), timeout %.1f s...\n', nframes, timeout_s);
    end

    s = serialport(port, 115200, "Timeout", 1);
    cleanup = onCleanup(@() delete(s)); %#ok<NASGU>
    flush(s);

    data = [];
    seq = zeros(1, max(1, min(double(nframes), 1e6)), 'uint32');
    if realtime
        seq = zeros(1, 0, 'uint32');
    end

    info = struct('port', string(port), 'nch', [], 'nsamp', [], 'fmt', [], ...
                  'droppedBytes', 0, 'badFrames', 0);

    buf = uint8([]);
    got = 0;
    deadline = tic;
    fftPlot = [];

    while realtime || got < nframes
        if ~realtime && toc(deadline) > timeout_s
            error('Timed out after %.1f s. Captured %d/%d frame(s).', timeout_s, got, nframes);
        end

        n = s.NumBytesAvailable;
        if n > 0
            buf = [buf; read(s, n, "uint8").']; %#ok<AGROW>
        else
            pause(0.01);
            continue;
        end

        while true
            idx = find_magic(buf, MAGIC);
            if isempty(idx)
                keep = min(numel(buf), numel(MAGIC) - 1);
                info.droppedBytes = info.droppedBytes + max(0, numel(buf) - keep);
                buf = buf(end-keep+1:end);
                break;
            end

            if idx > 1
                info.droppedBytes = info.droppedBytes + idx - 1;
                buf = buf(idx:end);
            end

            if numel(buf) < HDR
                break;
            end

            frameSeq = le_u32(buf(5:8));
            nch = double(buf(9));
            nsamp = double(le_u16(buf(10:11)));
            fmt = double(buf(12));

            if nch ~= NCH_EXPECTED || fmt ~= FMT_INT32 || nsamp <= 0
                info.badFrames = info.badFrames + 1;
                info.droppedBytes = info.droppedBytes + 1;
                buf = buf(2:end);
                continue;
            end

            frameLen = HDR + nch * nsamp * 4;
            if numel(buf) < frameLen + numel(MAGIC)
                break;   % need the next frame's magic to confirm this boundary
            end

            % Reject a stray "RAW1" inside the int32 payload: a genuine frame is
            % followed by another magic exactly one frame later. Without this a
            % coincidental magic in the samples desyncs the parser (seen as huge /
            % bipolar "samples" carrying the 0x52415731 bytes).
            if ~isequal(buf(frameLen+1:frameLen+numel(MAGIC)), MAGIC(:))
                info.badFrames = info.badFrames + 1;
                info.droppedBytes = info.droppedBytes + 1;
                buf = buf(2:end);
                continue;
            end

            payload = buf(HDR+1:frameLen);
            x = typecast(uint8(payload), 'int32');
            frameData = reshape(x, nsamp, nch);

            if isempty(data)
                if realtime
                    data = zeros(nsamp, nch, 1, 'int32');
                else
                    data = zeros(nsamp, nch, nframes, 'int32');
                end
                info.nch = nch;
                info.nsamp = nsamp;
                info.fmt = fmt;
            end

            got = got + 1;
            if realtime
                data(:, :, 1) = frameData;
                seq(end+1) = frameSeq; %#ok<AGROW>
                fftPlot = update_fft8_plot(fftPlot, frameData, FS, frameSeq);
                fprintf('seq=%u FFT updated\r\n', frameSeq);
            else
                data(:, :, got) = frameData;
                seq(got) = frameSeq;
                fprintf('  frame %d/%d: seq=%u nch=%d nsamp=%d\n', got, nframes, frameSeq, nch, nsamp);
            end

            buf = buf(frameLen+1:end);
            if ~realtime && got >= nframes
                break;
            end
        end
    end

    info.droppedBytes = double(info.droppedBytes);
    info.badFrames = double(info.badFrames);

    if ~realtime
        plot_capture_summary(data, seq, FS);
    end
end

function idx = find_magic(buf, magic)
    idx = [];
    if numel(buf) < numel(magic), return; end
    hit = strfind(buf.', magic);
    if ~isempty(hit), idx = hit(1); end
end

function v = le_u16(b)
    b = uint16(b);
    v = b(1) + bitshift(b(2), 8);
end

function v = le_u32(b)
    b = uint32(b);
    v = b(1) + bitshift(b(2), 8) + bitshift(b(3), 16) + bitshift(b(4), 24);
end

function rt = update_fft8_plot(rt, frameData, fs, frameSeq)
    nsamp = size(frameData, 1);
    nch = size(frameData, 2);
    x = double(frameData) / 2^23;
    x = x - mean(x, 1);

    w = 0.5 - 0.5 * cos(2*pi*(0:nsamp-1)'/(nsamp-1));
    X = abs(fft(x .* w, [], 1));
    half = 1:floor(nsamp/2);
    f = (half - 1) * fs / nsamp;
    db = 20*log10(X(half, :) + eps);

    if isempty(rt) || ~isfield(rt, 'fig') || ~isgraphics(rt.fig)
        rt.fig = figure('Name', 'Realtime FFT - 8 microphones', 'NumberTitle', 'off');
        layout = tiledlayout(rt.fig, 4, 2);
        layout.TileSpacing = 'compact';
        layout.Padding = 'compact';
        colors = lines(8);
        rt.ax = gobjects(1, 8);
        rt.line = gobjects(1, 8);
        for ch = 1:8
            rt.ax(ch) = nexttile(layout);
            rt.line(ch) = plot(rt.ax(ch), f, nan(size(f)), ...
                               'Color', colors(ch, :), 'LineWidth', 1.1);
            grid(rt.ax(ch), 'on');
            xlim(rt.ax(ch), [0 fs/2]);
            ylim(rt.ax(ch), [-120 20]);
            title(rt.ax(ch), sprintf('mic%d FFT', ch-1));
            xlabel(rt.ax(ch), 'Hz');
            ylabel(rt.ax(ch), 'dB');
        end
    end

    if ~all(isgraphics(rt.line)) || ~all(isgraphics(rt.ax))
        rt = [];
        rt = update_fft8_plot(rt, frameData, fs, frameSeq);
        return;
    end

    ymax = max([db(:); -20]);
    yl = [max(-140, ymax - 100), ymax + 10];
    for ch = 1:min(nch, 8)
        set(rt.line(ch), 'XData', f, 'YData', db(:, ch));
        ylim(rt.ax(ch), yl);
        title(rt.ax(ch), sprintf('mic%d FFT - seq %u', ch-1, frameSeq));
    end
    drawnow limitrate;
end

function plot_capture_summary(data, seq, fs)
    if isempty(data), return; end

    nsamp = size(data, 1);
    nch = size(data, 2);
    frameData = data(:, :, 1);
    x = double(frameData) / 2^23;
    t = (0:nsamp-1) / fs;

    figure('Name', sprintf('RAW1 mic capture seq=%u', seq(1)));
    tiledlayout(3, 1);

    nexttile;
    plot(t, x);
    grid on;
    xlabel('time (s)');
    ylabel('amplitude');
    title(sprintf('Time domain - %d mic channels', nch));

    nexttile;
    mn = min(frameData, [], 1);
    mx = max(frameData, [], 1);
    bar([double(mn(:)), double(mx(:))]);
    grid on;
    xlabel('channel');
    ylabel('raw int32');
    title('Per-channel min/max');
    legend('min', 'max');

    nexttile;
    hold on;
    grid on;
    nsamp = size(frameData, 1);
    w = 0.5 - 0.5 * cos(2*pi*(0:nsamp-1)'/(nsamp-1));
    f = (0:floor(nsamp/2)-1) * fs / nsamp;
    colors = lines(nch);
    for ch = 1:nch
        y = double(frameData(:, ch)) / 2^23;
        y = y - mean(y);
        Y = abs(fft(y .* w));
        plot(f, 20*log10(Y(1:numel(f)) + eps), 'Color', colors(ch, :), ...
             'DisplayName', sprintf('mic%d', ch-1));
    end
    xlabel('frequency (Hz)');
    ylabel('dB');
    title('FFT - all mic channels');
    legend('Location', 'eastoutside');
end
