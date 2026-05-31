function results = mic_fft_test(port, nframes, timeout_s)
%MIC_FFT_TEST Capture RAW1 frames over USB CDC and verify the mics read real data.
%
%   results = mic_fft_test()                 % COM12, 16 frames
%   results = mic_fft_test("COM12", 32)      % average 32 frames for a cleaner spectrum
%   results = mic_fft_test("COM12", 16, 30)  % 30 s capture timeout
%
% Unlike read_mic_raw (which just dumps/plots the stream), this tool judges whether
% each microphone is delivering genuine, independent audio. It averages the FFT over
% several frames, then per channel reports DC offset, AC RMS, the dominant tone, its
% prominence above the noise floor, and spectral flatness, and prints a verdict:
%
%   TONE @ f Hz  - a clear spectral peak (play a tone/whistle near the mics to see this)
%   NOISE        - broadband ambient content, mic is live
%   DC-DOMINATED - almost no AC vs a large DC term (suspect: unsigned/clamped data)
%   DEAD         - essentially constant, mic not capturing
%
% It also cross-correlates the channels: if several read (near-)identical samples the
% mics are not independent (wiring/clock/deinterleave problem), which is reported too.
%
% Use the OTG USB CDC COM port (e.g. COM12), NOT the ST-LINK VCP status port (COM3).

    if nargin < 1 || isempty(port),      port = "COM12"; end
    if nargin < 2 || isempty(nframes),   nframes = 16;   end
    if nargin < 3 || isempty(timeout_s), timeout_s = 20; end

    nframes = double(nframes);
    if ~isfinite(nframes) || nframes < 1
        error('mic_fft_test:nframes', 'nframes must be a finite positive integer.');
    end

    FS         = 16000;     % sample rate (Hz), see CLAUDE.md
    FULLSCALE  = 2^23;      % 24-bit signed full scale
    TONE_PROM_DB = 12;      % peak this far above the noise floor => "TONE"
    NOISE_FLAT   = 0.20;    % spectral flatness above this (with AC) => "NOISE"
    DEAD_RMS_LSB = 2;       % AC RMS below this (raw counts) => "DEAD"
    IDENT_CORR   = 0.999;   % cross-channel correlation above this => not independent

    % ---- capture (reuse the proven RAW1 reader, suppress its figure) --------
    figsBefore = findall(0, 'Type', 'figure');
    [data, seq] = read_mic_raw(port, nframes, timeout_s);
    figsAfter = findall(0, 'Type', 'figure');
    extra = setdiff(figsAfter, figsBefore);
    if ~isempty(extra), close(extra); end

    if isempty(data)
        error('mic_fft_test:noData', 'No frames captured from %s.', string(port));
    end

    nsamp = size(data, 1);
    nch   = size(data, 2);
    ngot  = size(data, 3);

    % ---- per-frame AC-couple, then average the power spectrum ---------------
    w   = 0.5 - 0.5*cos(2*pi*(0:nsamp-1)'/(nsamp-1));  % Hann (no toolbox dep), matches TASK-07
    cg  = sum(w);                      % coherent gain for amplitude scaling
    nfh = floor(nsamp/2);
    f   = (0:nfh-1).' * FS / nsamp;

    ampSpec = zeros(nfh, nch);         % averaged amplitude spectrum (normalized 0..1)
    acRef   = zeros(nsamp, nch);       % AC-coupled first frame, for correlation/time plot
    dcCounts  = zeros(1, nch);
    rmsCounts = zeros(1, nch);

    for ch = 1:nch
        x  = double(squeeze(data(:, ch, :)));      % nsamp x ngot (raw counts)
        if ngot == 1, x = x(:); end
        dcCounts(ch)  = mean(x(:));
        ac = x - mean(x, 1);                        % remove per-frame DC
        rmsCounts(ch) = sqrt(mean(ac(:).^2));
        acRef(:, ch)  = ac(:, 1);

        P = zeros(nfh, 1);
        for k = 1:ngot
            X = fft((ac(:, k) / FULLSCALE) .* w);
            mag = (2 / cg) * abs(X(1:nfh));         % single-sided amplitude (full scale = 1)
            P = P + mag.^2;
        end
        ampSpec(:, ch) = sqrt(P / ngot);
    end

    specDb = 20*log10(ampSpec + eps);

    % ---- per-channel metrics + verdict --------------------------------------
    peakHz   = zeros(1, nch);
    peakDb   = zeros(1, nch);
    promDb   = zeros(1, nch);
    flatness = zeros(1, nch);
    verdict  = strings(1, nch);

    bins = 2:nfh;                       % skip DC bin for tone/floor stats
    for ch = 1:nch
        pw = ampSpec(bins, ch).^2;
        [pk, kpk] = max(ampSpec(bins, ch));
        peakHz(ch) = f(bins(kpk));
        peakDb(ch) = 20*log10(pk + eps);
        floorPw    = median(pw);
        promDb(ch) = 10*log10((pk^2 + eps) / (floorPw + eps));
        flatness(ch) = exp(mean(log(pw + eps))) / (mean(pw) + eps);

        if rmsCounts(ch) < DEAD_RMS_LSB
            verdict(ch) = "DEAD";
        elseif abs(dcCounts(ch)) > 10 * rmsCounts(ch)
            verdict(ch) = "DC-DOMINATED";
        elseif promDb(ch) > TONE_PROM_DB
            verdict(ch) = sprintf("TONE @ %.0f Hz", peakHz(ch));
        elseif flatness(ch) > NOISE_FLAT
            verdict(ch) = "NOISE";
        else
            verdict(ch) = "low-level";
        end
    end

    % ---- cross-channel independence -----------------------------------------
    C = corrcoef(acRef);
    identPairs = {};
    for a = 1:nch
        for b = a+1:nch
            if abs(C(a, b)) > IDENT_CORR
                identPairs{end+1} = sprintf('mic%d~mic%d (r=%.4f)', a-1, b-1, C(a, b)); %#ok<AGROW>
            end
        end
    end

    % ---- console report -----------------------------------------------------
    fprintf('\n=== MIC FFT TEST (%s) ===\n', string(port));
    fprintf('frames=%d  nsamp=%d  nch=%d  Fs=%d Hz  bin=%.2f Hz\n', ...
            ngot, nsamp, nch, FS, FS/nsamp);
    fprintf('%-4s %12s %12s %9s %9s %9s   %s\n', ...
            'mic', 'dc(cnt)', 'rmsAC(cnt)', 'peakHz', 'prom_dB', 'flatness', 'verdict');
    for ch = 1:nch
        fprintf('%-4d %12.0f %12.1f %9.0f %9.1f %9.3f   %s\n', ...
                ch-1, dcCounts(ch), rmsCounts(ch), peakHz(ch), promDb(ch), ...
                flatness(ch), verdict(ch));
    end

    nLive = sum(~ismember(verdict, ["DEAD", "DC-DOMINATED"]));
    fprintf('\nLive channels: %d/%d\n', nLive, nch);
    if all(verdict == "DC-DOMINATED")
        fprintf('[WARN] All channels are DC-dominated (positive-only / no AC).\n');
        fprintf('       The mics are NOT delivering real audio - check analog front-end / SAI data.\n');
    elseif any(verdict == "DEAD")
        fprintf('[WARN] Dead channel(s) present: %s\n', strjoin(string(find(verdict=="DEAD")-1), ', '));
    end
    if ~isempty(identPairs)
        fprintf('[WARN] Near-identical channels (mics not independent):\n');
        fprintf('       %s\n', strjoin(string(identPairs), ', '));
    elseif nch > 1
        fprintf('[ OK ] Channels are independent (max |corr|=%.3f).\n', ...
                max(abs(C(~eye(nch)))));
    end
    fprintf('Tip: whistle or play a steady tone near the array - a TONE verdict at that\n');
    fprintf('     frequency on every mic confirms the full capture path is correct.\n\n');

    % ---- plots --------------------------------------------------------------
    plot_fft_grid(f, specDb, peakHz, peakDb, verdict, FS);
    plot_overview(acRef, ampSpec, f, rmsCounts, FS, seq);

    % ---- return -------------------------------------------------------------
    results = struct('port', string(port), 'frames', ngot, 'nsamp', nsamp, ...
                     'nch', nch, 'fs', FS, 'freq', f, 'specDb', specDb, ...
                     'dcCounts', dcCounts, 'rmsCounts', rmsCounts, ...
                     'peakHz', peakHz, 'peakDb', peakDb, 'promDb', promDb, ...
                     'flatness', flatness, 'verdict', verdict, 'corr', C, ...
                     'identicalPairs', {identPairs});
end

function plot_fft_grid(f, specDb, peakHz, peakDb, verdict, fs)
    nch = size(specDb, 2);
    figure('Name', 'Mic FFT test - averaged spectrum per channel', 'NumberTitle', 'off');
    rows = ceil(nch/2);
    layout = tiledlayout(rows, 2);
    layout.TileSpacing = 'compact';
    layout.Padding = 'compact';
    colors = lines(nch);
    ymax = max([specDb(:); -20]);
    yl = [max(-160, ymax - 120), ymax + 10];
    for ch = 1:nch
        ax = nexttile(layout);
        plot(ax, f, specDb(:, ch), 'Color', colors(ch, :), 'LineWidth', 1.0);
        hold(ax, 'on');
        plot(ax, peakHz(ch), peakDb(ch), 'rv', 'MarkerFaceColor', 'r', 'MarkerSize', 5);
        grid(ax, 'on');
        xlim(ax, [0 fs/2]);
        ylim(ax, yl);
        title(ax, sprintf('mic%d - %s', ch-1, verdict(ch)));
        xlabel(ax, 'Hz');
        ylabel(ax, 'dBFS');
    end
end

function plot_overview(acRef, ampSpec, f, rmsCounts, fs, seq)
    nsamp = size(acRef, 1);
    nch = size(acRef, 2);
    t = (0:nsamp-1) / fs;
    if isempty(seq), seqStr = '?'; else, seqStr = sprintf('%u..%u', seq(1), seq(end)); end

    figure('Name', sprintf('Mic FFT test - overview (seq %s)', seqStr), 'NumberTitle', 'off');
    tiledlayout(3, 1);

    nexttile;
    plot(t, acRef);
    grid on;
    xlabel('time (s)'); ylabel('AC counts');
    title(sprintf('Time domain (AC-coupled, %d channels, first frame)', nch));

    nexttile;
    hold on; grid on;
    colors = lines(nch);
    for ch = 1:nch
        plot(f, 20*log10(ampSpec(:, ch) + eps), 'Color', colors(ch, :), ...
             'DisplayName', sprintf('mic%d', ch-1));
    end
    xlim([0 fs/2]);
    xlabel('frequency (Hz)'); ylabel('dBFS');
    title('Averaged FFT - all channels overlaid');
    legend('Location', 'eastoutside');

    nexttile;
    bar(0:nch-1, rmsCounts);
    grid on;
    xlabel('mic channel'); ylabel('AC RMS (raw counts)');
    title('Per-channel signal level (AC RMS)');
end
