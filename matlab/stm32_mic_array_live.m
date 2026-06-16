function stm32_mic_array_live(varargin)
% stm32_mic_array_live  Live DOA visualizer for the STM32H7 8-mic UCA.
%
%   stm32_mic_array_live()            -- uses default COM_PORT (see config)
%   stm32_mic_array_live('COM7')      -- override COM port
%   stm32_mic_array_live('sim')       -- simulation mode (no hardware needed)
%
% USB CDC frame format (from STM32 USB_Task):
%   Bytes  0– 3 : magic 'RAW1'
%   Bytes  4– 7 : seq  (uint32 LE)
%   Byte   8    : nch  = 8
%   Bytes  9–10 : nsamp = 1024 (uint16 LE)
%   Byte  11    : fmt  = 0 (int32 LE)
%   Bytes 12+   : int32 channel-major payload  (8 × 1024 × 4 = 32768 bytes)
%                 ch0[0..1023], ch1[0..1023], ..., ch7[0..1023]
%                 Values are 24-bit sign-extended; divide by 2^23 to normalise.
%
% Array geometry: UCA diameter 80 mm, ch0 at 0° (+x), CCW.
%   ch i → angle = i×45°,  x = R·cos, y = R·sin,  R = 40 mm.

% =========================================================================
%  Configuration
% =========================================================================
COM_PORT   = 'COM12';    % USB CDC virtual COM port (adjust to match Device Manager)
Fs         = 16000;     % sample rate (Hz)
N_SAMP     = 1024;      % samples per channel per frame
N_CH       = 8;         % mic channels
R_M        = 0.040;     % UCA radius (m)
C_MPS      = 343.0;     % speed of sound (m/s)
CONTRAST_MIN = 1.2;     % SRP contrast gate: below this = no directional source
MAGIC      = uint8('RAW1');
HDR_BYTES  = 12;
PAYLOAD_WORDS = N_CH * N_SAMP;       % int32 words
FRAME_BYTES   = HDR_BYTES + PAYLOAD_WORDS * 4;   % 32780 bytes

SIM_MODE   = false;
if nargin >= 1
    arg = varargin{1};
    if strcmpi(arg, 'sim')
        SIM_MODE = true;
    else
        COM_PORT = arg;
    end
end

% =========================================================================
%  Mic geometry — UCA 80mm, each SAI pair wires two OPPOSITE mics.
%  pair p: ch_L = p*2  at  p*45 deg
%           ch_R = p*2+1 at  p*45+180 deg
%  ch0=0°, ch1=180°, ch2=45°, ch3=225°, ch4=90°, ch5=270°, ch6=135°, ch7=315°
% =========================================================================
ang_deg = [ 0, 180, 45, 225, 90, 270, 135, 315 ];   % (1×8), matches mic_pos in STM32
mic_x   = R_M * cosd(ang_deg);
mic_y   = R_M * sind(ang_deg);
mic_pos = [mic_x(:), mic_y(:)];  % (8×2)

% DOA look-up table — HARDCODED (mirrors STM32 DOA_Init, table-search version).
% doa_table(a,k) = expected TDOA lag (samples) on baseline k (mic0 vs mic k)
% for candidate azimuth DOA_ANGLES(a).
% Generated for: UCA R=40mm, Fs=16000, C=343 m/s,
% ang_deg = [0 180 45 225 90 270 135 315], formula (Fs/C)*dot(d_k, u_a).
DOA_ANGLES = 0:45:315;                          % (1×8) candidate azimuths
doa_table = [ ...                               % (8×7)  cols: ch1..ch7
  -3.731778  -0.546506  -3.185272  -1.865889  -1.865889  -3.185272  -0.546506 ;  % az=0
  -2.638766   0.546506  -3.185272   0.000000  -2.638766  -1.319383  -1.319383 ;  % az=45
   0.000000   1.319383  -1.319383   1.865889  -1.865889   1.319383  -1.319383 ;  % az=90
   2.638766   1.319383   1.319383   2.638766   0.000000   3.185272  -0.546506 ;  % az=135
   3.731778   0.546506   3.185272   1.865889   1.865889   3.185272   0.546506 ;  % az=180
   2.638766  -0.546506   3.185272   0.000000   2.638766   1.319383   1.319383 ;  % az=225
   0.000000  -1.319383   1.319383  -1.865889   1.865889  -1.319383   1.319383 ;  % az=270
  -2.638766  -1.319383  -1.319383  -2.638766   0.000000  -3.185272   0.546506 ]; % az=315

% =========================================================================
%  Open serial port (skip in sim mode)
% =========================================================================
s = [];
if ~SIM_MODE
    s = open_port(COM_PORT, FRAME_BYTES);
else
    fprintf('[SIM MODE] Generating synthetic frames.\n');
end

% =========================================================================
%  Build figure
% =========================================================================
fig = figure('Name', 'STM32 8-mic UCA — Live DOA', ...
             'Position', [60 60 1300 720], ...
             'Color', [0.08 0.08 0.08], ...
             'CloseRequestFcn', @(~,~) on_close());
clf(fig);

%--- Subplot 1: Mic array + DOA arrow (top-left) -------------------------
ax_arr = subplot(2,3,[1,4], 'Parent', fig);
hold(ax_arr, 'on'); axis(ax_arr, 'equal'); grid(ax_arr, 'on');
set(ax_arr, 'Color',[0.1 0.1 0.1], 'XColor','w', 'YColor','w', ...
            'GridColor',[0.25 0.25 0.25], 'FontSize', 9);

% Draw circle outline
th = linspace(0, 2*pi, 200);
plot(ax_arr, R_M*1e3*cos(th), R_M*1e3*sin(th), '--', ...
     'Color',[0.35 0.35 0.35], 'LineWidth',0.8);

% Draw diameter lines connecting each opposite pair (pair0..3)
pair_colors = [1 0.4 0.4; 0.4 1 0.4; 0.4 0.7 1; 1 0.8 0.2];
for p = 0:3
    ch_L = p*2 + 1;  ch_R = p*2 + 2;   % MATLAB 1-based
    plot(ax_arr, mic_x([ch_L, ch_R])*1e3, mic_y([ch_L, ch_R])*1e3, ...
         '-', 'Color', [pair_colors(p+1,:) 0.35], 'LineWidth', 1.2);
end

% Mics (colour-coded by pair)
mic_pair_colors = pair_colors(ceil((1:N_CH)/2), :);
scatter(ax_arr, mic_x*1e3, mic_y*1e3, 100, mic_pair_colors, 'filled', ...
        'MarkerEdgeColor','w', 'LineWidth',0.6);
pair_label = {'L','R','L','R','L','R','L','R'};
for i = 1:N_CH
    lbl_r = (R_M + 0.013) * 1e3;
    pair_idx = floor((i-1)/2);
    text(ax_arr, lbl_r*cosd(ang_deg(i)), lbl_r*sind(ang_deg(i)), ...
         sprintf('ch%d\np%d%s\n%d°', i-1, pair_idx, pair_label{i}, ang_deg(i)), ...
         'Color','w', 'FontSize',6.5, 'HorizontalAlignment','center');
end

% Axes labels at origin
plot(ax_arr, [0 R_M*1e3*0.6], [0 0], 'r-', 'LineWidth',1.5);
plot(ax_arr, [0 0], [0 R_M*1e3*0.6], 'g-', 'LineWidth',1.5);
text(ax_arr, R_M*1e3*0.65, -3, '+x', 'Color','r','FontSize',8);
text(ax_arr, 2, R_M*1e3*0.65, '+y', 'Color','g','FontSize',8);

% Wavefront lines (updated each frame, start hidden)
h_wfront = gobjects(5,1);
for w = 1:5
    h_wfront(w) = plot(ax_arr, [0 0],[0 0], 'Color',[1 0.8 0 0.4], 'LineWidth', 0.8);
end

% DOA arrow (filled quiver)
h_arrow  = quiver(ax_arr, 0, 0, 0, 0, 0, ...
                  'Color','r', 'LineWidth',2.5, 'MaxHeadSize',0.6);
h_doatxt = text(ax_arr, 0, -(R_M*1e3+18), 'az: ---  el: ---', ...
                'Color',[1 0.9 0.2], 'FontSize',11, ...
                'HorizontalAlignment','center', 'FontWeight','bold');

xlim(ax_arr, [-70 70]); ylim(ax_arr, [-70 70]);
xlabel(ax_arr, 'x (mm)', 'Color','w');
ylabel(ax_arr, 'y (mm)', 'Color','w');
title(ax_arr, 'Mic Array + DOA', 'Color','w', 'FontSize',10);

%--- Subplot 2: Polar DOA history (top-centre+right) ----------------------
ax_tmp = subplot(2,3,[2,3], 'Parent', fig);
pax = polaraxes('Parent', fig, 'Position', ax_tmp.Position);
delete(ax_tmp);
set(pax, 'Color',[0.1 0.1 0.1], 'GridColor',[0.35 0.35 0.35], ...
         'ThetaDir','counterclockwise', 'ThetaZeroLocation','right', ...
         'RColor','w', 'ThetaColor','w', 'FontSize',9);
pax.RLim = [0 1.1];
pax.RTick = [0.25 0.5 0.75 1.0];
pax.RTickLabel = {'75°','60°','30°','0° el'};
hold(pax, 'on');

MAX_HIST = 60;    % frames of history
az_hist  = nan(1, MAX_HIST);
el_hist  = nan(1, MAX_HIST);
hist_ptr = 0;
cmap = jet(MAX_HIST);

h_hist = polarscatter(pax, [], [], 28, [], 'filled', 'MarkerFaceAlpha',0.8);
colormap(pax, cmap);
h_ptitle = title(pax, 'DOA History', 'Color','w', 'FontSize',10);

%--- Subplot 3: Waveforms (bottom-left) ------------------------------------
ax_wav = subplot(2,3,5, 'Parent', fig);
hold(ax_wav,'on'); grid(ax_wav,'on');
set(ax_wav,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.25 0.25 0.25],'FontSize',9);
% t_rel: relative offset within a frame (0..63.9 ms), used for XData width.
% Absolute position is shifted each frame via XLim.
t_rel_ms = (0:N_SAMP-1) / Fs * 1e3;   % (1×N_SAMP) ms, frame-relative
ch_colors = parula(N_CH);
WAVE_OFFSET = 1.5;
h_wav = gobjects(N_CH,1);
for i = 1:N_CH
    h_wav(i) = plot(ax_wav, t_rel_ms, zeros(1,N_SAMP) + (i-1)*WAVE_OFFSET, ...
                    'Color', ch_colors(i,:), 'LineWidth', 0.8);
end
yticks(ax_wav, (0:N_CH-1)*WAVE_OFFSET);
yticklabels(ax_wav, arrayfun(@(i) sprintf('ch%d',i), 0:N_CH-1, 'uni',0));
xlim(ax_wav, [0 t_rel_ms(end)]);
ylim(ax_wav, [-1 (N_CH-1)*WAVE_OFFSET+1]);
xlabel(ax_wav,'Time in frame (ms)','Color','w');
title(ax_wav,'Waveforms','Color','w','FontSize',10);

%--- Subplot 4: GCC-PHAT (bottom-right) ------------------------------------
ax_gcc = subplot(2,3,6, 'Parent', fig);
hold(ax_gcc,'on'); grid(ax_gcc,'on');
set(ax_gcc,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.25 0.25 0.25],'FontSize',9);

max_lag_us = ceil((2*R_M / C_MPS) * 1e6 * 1.5);   % ±1.5× max physical TDOA
lag_us  = (-N_SAMP/2 : N_SAMP/2-1) / Fs * 1e6;
vis_mask = abs(lag_us) <= max_lag_us;

h_gcc = gobjects(N_CH-1,1);
for k = 1:N_CH-1
    h_gcc(k) = plot(ax_gcc, lag_us(vis_mask), zeros(1,sum(vis_mask)), ...
                    'Color', ch_colors(k+1,:), 'LineWidth', 0.9);
end
h_gcc_leg = legend(ax_gcc, arrayfun(@(k) sprintf('ch0↔ch%d',k), 1:N_CH-1, 'uni',0), ...
                   'TextColor','w','Color',[0.15 0.15 0.15],'FontSize',7, ...
                   'Location','northeast');
xline(ax_gcc, 0, 'Color',[0.5 0.5 0.5], 'LineStyle','--', 'LineWidth',0.8);
xlim(ax_gcc, [-max_lag_us max_lag_us]);
xlabel(ax_gcc,'Lag (µs)','Color','w');
ylabel(ax_gcc,'GCC-PHAT','Color','w');
title(ax_gcc,'GCC-PHAT  ch0 vs others','Color','w','FontSize',10);

% =========================================================================
%  State
% =========================================================================
running   = true;
frame_cnt = 0;
drop_cnt  = 0;
last_seq  = -1;

% =========================================================================
%  Main loop
% =========================================================================
while running && ishandle(fig)
    % --- Acquire one frame -----------------------------------------------
    if SIM_MODE
        [frame_data, seq, ok] = sim_frame(frame_cnt, N_CH, N_SAMP, Fs, C_MPS, mic_pos);
    else
        % USB CDC dies whenever the firmware is reflashed (device re-enumerates)
        % — catch the dead-port error and reconnect instead of crashing.
        try
            [frame_data, seq, ok] = read_frame(s, N_CH, N_SAMP, HDR_BYTES, MAGIC, FRAME_BYTES);
        catch err
            fprintf('Serial error: %s\nReconnecting %s ...\n', err.message, COM_PORT);
            ok = false;
            delete(s);  s = [];
            pause(2);                       % let the CDC device re-enumerate
            try
                s = open_port(COM_PORT, FRAME_BYTES);
                last_seq = -1;              % seq counter restarts after reset
            catch
                fprintf('Reconnect failed — retrying...\n');
            end
        end
    end

    if ~ok
        drop_cnt = drop_cnt + 1;
        if drop_cnt > 20
            fprintf('Too many read errors — check COM port and USB connection.\n');
            break;
        end
        continue;
    end
    drop_cnt  = 0;
    frame_cnt = frame_cnt + 1;
    seq_d = seq(1);        % seq is already double scalar; (1) guards against edge case
    if last_seq >= 0      % split && into nested if — avoids scalar-logical type issues
        if seq_d ~= last_seq + 1
            fprintf('Gap detected: expected seq %d got %d\n', last_seq+1, seq_d);
        end
    end
    last_seq = seq_d;

    % Normalise: 24-bit sign-extended stored as int32, → float [-1,1]
    data_f = double(frame_data) / 8388608.0;   % (N_CH × N_SAMP)

    % --- GCC-PHAT: ch0 vs ch1..7 -----------------------------------------
    lags_samp = zeros(N_CH-1, 1);
    gcc_all   = zeros(N_CH-1, N_SAMP);
    for k = 1:N_CH-1
        [gcc_full, lags_samp(k)] = gcc_phat(data_f(1,:), data_f(k+1,:), N_SAMP);
        gcc_all(k,:) = gcc_full;
    end

    % --- DOA estimate (SRP delay-and-sum, strongest source per direction) --
    [az, ~, contrast] = doa_srp(data_f, doa_table, DOA_ANGLES);

    % --- Source-presence check (mirrors firmware gate contrast > 1.2) -----
    src_present = contrast > CONTRAST_MIN;

    % --- Update history (only frames with a real source) ------------------
    if src_present
        hist_ptr = mod(hist_ptr, MAX_HIST) + 1;
        az_hist(hist_ptr) = az;
        el_hist(hist_ptr) = 0;
    end

    % --- Update wavefront lines on array plot ----------------------------
    wf_spacing = R_M * 0.4 * 1e3;   % spacing between wavefront lines (mm)
    for w = 1:5
        d_offset = (w - 3) * wf_spacing;
        % Line perpendicular to DOA direction, offset by d_offset
        px = d_offset * cosd(az);
        py = d_offset * sind(az);
        perp_len = 80;
        dx = perp_len * sind(az);
        dy = perp_len * (-cosd(az));
        if src_present
            set(h_wfront(w), 'XData', [px-dx, px+dx], 'YData', [py-dy, py+dy]);
        else
            set(h_wfront(w), 'XData', [nan nan], 'YData', [nan nan]);
        end
    end

    % --- Update DOA arrow ------------------------------------------------
    arr_len = 50;   % mm
    if src_present
        set(h_arrow, 'UData', arr_len*cosd(az), 'VData', arr_len*sind(az), ...
                     'Color', [1 0.3 0.3]);
        set(h_doatxt, 'String', sprintf('az: %.0f°   contrast: %.2f', az, contrast), ...
                      'Color', 'w');
    else
        set(h_arrow, 'UData', 0, 'VData', 0);
        set(h_doatxt, 'String', sprintf('NO SOURCE   contrast: %.2f', contrast), ...
                      'Color', [0.5 0.5 0.5]);
    end

    % --- Update polar scatter --------------------------------------------
    valid = ~isnan(az_hist);
    if any(valid)
        az_r   = deg2rad(az_hist(valid));
        r_vals = cosd(el_hist(valid));   % r=1 → in-plane, r=0 → overhead
        n_v    = sum(valid);
        ages   = linspace(0.2, 1.0, MAX_HIST);
        set(h_hist, 'ThetaData', az_r, 'RData', r_vals, ...
                    'CData', ages(1:n_v), 'SizeData', 20+30*ages(1:n_v));
    end
    set(h_ptitle, 'String', ...
        sprintf('DOA History  [frame %d, seq %d]', frame_cnt, seq));

    % --- Update waveforms (absolute sample index shown in title) ----------
    abs_sample_start = double(seq) * N_SAMP;   % first sample of this frame
    title(ax_wav, sprintf('Waveforms  [abs sample %d .. %d]', ...
          abs_sample_start, abs_sample_start + N_SAMP - 1), ...
          'Color','w', 'FontSize',9);
    for i = 1:N_CH
        set(h_wav(i), 'YData', data_f(i,:)*0.6 + (i-1)*WAVE_OFFSET);
    end

    % --- Update GCC-PHAT display -----------------------------------------
    gcc_vis = gcc_all(:, vis_mask);
    for k = 1:N_CH-1
        set(h_gcc(k), 'YData', gcc_vis(k,:));
    end
    all_gcc = gcc_vis(:);
    if ~isempty(all_gcc) && max(abs(all_gcc)) > 0
        ylim(ax_gcc, [-0.2, max(all_gcc)*1.15]);
    end

    drawnow limitrate;

    if SIM_MODE, pause(0.064); end   % ~15.6 fps (matches real 1024/16kHz)
end

% =========================================================================
%  Cleanup
% =========================================================================
if ~isempty(s)
    clear s;
    fprintf('Serial port closed.\n');
end
fprintf('Total frames: %d\n', frame_cnt);

    function on_close()
        running = false;
        delete(fig);
    end
end   % main function

% =========================================================================
%  Local functions
% =========================================================================

function [data, seq, ok] = read_frame(s, N_CH, N_SAMP, HDR_BYTES, MAGIC, FRAME_BYTES)
% Read and sync one raw frame from the serial port.
% Returns data (N_CH×N_SAMP int32), seq, and ok flag.
    data = []; seq = 0; ok = false;

    % Drop the backlog if plotting fell behind the 512 KB/s stream — reading
    % stale data byte-by-byte is what used to stall the CDC link entirely.
    if s.NumBytesAvailable > 3 * FRAME_BYTES
        flush(s, 'input');
    end

    % Sync: bulk-read chunks and scan for the magic (never 1-byte reads).
    buf = uint8(read(s, 4, 'uint8'));
    buf = buf(:)';
    for attempt = 1:30
        if isequal(buf, MAGIC), break; end
        n     = max(min(double(s.NumBytesAvailable), FRAME_BYTES), 64);
        chunk = uint8(read(s, n, 'uint8'));
        win   = [buf, chunk(:)'];
        k     = strfind(win, MAGIC);
        if ~isempty(k)
            % Re-queue everything after the magic is not possible — instead
            % consume up to the magic and read the rest of this frame below.
            extra = win(k(1)+4:end);              % bytes already pulled past magic
            buf   = MAGIC;
            % Stash the surplus so header/payload reads can use it first.
            s.UserData = extra;
            break;
        end
        buf = win(end-3:end);
        if attempt == 30
            warning('stm32_mic_array:sync', 'Cannot find magic RAW1.');
            return;
        end
    end
    if ~isequal(buf, MAGIC), return; end

    % Helper: serve bytes from the surplus stash first, then the port.
    stash = uint8([]);
    if ~isempty(s.UserData), stash = uint8(s.UserData(:)'); s.UserData = []; end
    need  = (HDR_BYTES - 4) + N_CH * N_SAMP * 4;  % header rest + payload bytes
    if numel(stash) < need
        more  = uint8(read(s, need - numel(stash), 'uint8'));
        stash = [stash, more(:)'];
    end
    hdr_pl = stash(1:need);

    % Header: 8 bytes (seq + nch + nsamp_lo + nsamp_hi + fmt)
    hdr   = hdr_pl(1:HDR_BYTES-4);
    % Decode uint32 LE manually — avoids typecast shape ambiguity (row vs col)
    seq   = double(hdr(1)) + double(hdr(2))*256 + ...
            double(hdr(3))*65536 + double(hdr(4))*16777216;
    nch   = double(hdr(5));
    nsamp = double(hdr(6)) + double(hdr(7)) * 256;

    if nch ~= N_CH || nsamp ~= N_SAMP
        warning('stm32_mic_array:header', ...
                'Header mismatch: nch=%d nsamp=%d (expected %d %d)', ...
                nch, nsamp, N_CH, N_SAMP);
        return;
    end

    % Payload: N_CH*N_SAMP int32 values (little-endian)
    raw  = typecast(hdr_pl(HDR_BYTES-4+1:end), 'int32');   % (N_CH*N_SAMP × 1)
    % C layout: row-major [N_CH][N_SAMP] → ch0 first, ch1 next, ...
    data = reshape(double(raw), [N_SAMP, N_CH])';          % (N_CH × N_SAMP)
    ok   = true;
end


function [corr_shift, lag_samp] = gcc_phat(x, y, N)
% GCC-PHAT between two real signals x and y (length N).
% Returns the full fftshift'd correlation (length N) and the peak lag in samples.
    X    = fft(double(x), N);
    Y    = fft(double(y), N);
    G    = X .* conj(Y);
    dnom = max(abs(G), 1e-10);
    corr = real(ifft(G ./ dnom));
    corr_shift = fftshift(corr);
    [~, idx]   = max(corr_shift);
    lag_samp   = idx - N/2 - 1;   % signed, sub-sample via parabolic interp
    % Parabolic interpolation (mirrors STM32 TASK-11)
    if idx > 1 && idx < N
        ym1 = corr_shift(idx-1);
        y0  = corr_shift(idx);
        yp1 = corr_shift(idx+1);
        denom = 2*(2*y0 - ym1 - yp1);
        if abs(denom) > 1e-10
            lag_samp = (idx - N/2 - 1) + (yp1 - ym1) / denom;
        end
    end
end


function s = open_port(com_port, frame_bytes)
% Open the USB CDC virtual COM port for the RAW1 stream.
    fprintf('Opening %s  (FRAME_BYTES=%d)...\n', com_port, frame_bytes);
    s = serialport(com_port, 115200);   % baud ignored by CDC; any value works
    s.Timeout = 5;
    flush(s);
    fprintf('Port open. Streaming...\n');
end


function [az, el, contrast] = doa_srp(data_f, doa_table, angles_deg)
% SRP delay-and-sum DOA (mirrors STM32 DOA_SRP).
% For each of the 8 fixed 45-deg directions, advance each channel by its
% expected integer delay, sum the aligned channels, and take the beam power.
% The direction with the largest power wins (only the strongest source).
% contrast = peak power / mean power (>=1); ~1 means no directional source.
%
% Note on sign: doa_table holds the expected GCC lag (+(Fs/C)·dot(d_k,u));
% the physical delay of ch k vs ch0 is the NEGATIVE of that, so the
% alignment shift is round(-doa_table).
    [n_ch, N] = size(data_f);
    n_az  = numel(angles_deg);
    dmax  = ceil(max(abs(doa_table(:)))) + 1;
    n_rng = (1 + dmax):(N - dmax);
    pw    = zeros(n_az, 1);
    for a = 1:n_az
        y = data_f(1, n_rng);
        for k = 1:n_ch-1
            sh = round(-doa_table(a, k));
            y  = y + data_f(k+1, n_rng + sh);
        end
        pw(a) = sum(y.^2);
    end
    [best_p, best_a] = max(pw);
    az = angles_deg(best_a);
    contrast = best_p / (mean(pw) + 1e-20);
    el = 0;                                   % SRP planar: elevation not estimated
end


function [data, seq, ok] = sim_frame(frame_cnt, N_CH, N_SAMP, Fs, C, mic_pos)
% Synthetic frame: a plane wave from a slowly rotating azimuth.
% t_abs gives a continuous absolute sample axis so signal phase is coherent
% across frame boundaries (mirrors what the STM32 DMA actually captures).
    ok  = true;
    seq = double(frame_cnt);

    az_true = mod(frame_cnt * 3, 360);   % rotates 3 deg/frame (~47 deg/s at 15.6 fps)
    el_true = 15;

    ux = cosd(az_true) * cosd(el_true);
    uy = sind(az_true) * cosd(el_true);

    % Absolute sample index: sample n of frame f → global index f*N_SAMP + n
    abs_idx = frame_cnt * N_SAMP + (0:N_SAMP-1);   % (1×N_SAMP) integers
    t_abs   = abs_idx / Fs;                          % absolute time axis (s)

    f0   = 800 + 400*sin(2*pi * 0.5 * frame_cnt / 15.6);   % 800–1200 Hz chirp
    data = zeros(N_CH, N_SAMP, 'int32');

    for i = 1:N_CH
        dx = mic_pos(i,1) - mic_pos(1,1);
        dy = mic_pos(i,2) - mic_pos(1,2);
        delay_s = -(dx*ux + dy*uy) / C;   % propagation delay relative to mic0 (s)
        sig = sin(2*pi * f0 * (t_abs - delay_s));   % phase-continuous across frames
        sig = sig + 0.05 * randn(1, N_SAMP);        % SNR ~26 dB
        data(i,:) = int32(sig * 8388607);
    end
end
