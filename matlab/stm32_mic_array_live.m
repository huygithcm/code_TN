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

% DOA pseudo-inverse M (mirrors STM32 DOA_Init).
% D[k] = mic_pos[k+1] - mic_pos[0], k=0..6  → (7×2)
% u = pinv(D) * (lag_samples × C/Fs)  → 2D unit-direction estimate
D      = mic_pos(2:end, :) - mic_pos(1, :);   % (7×2)
M_pinv = (D' * D) \ D';                        % (2×7)

% =========================================================================
%  Open serial port (skip in sim mode)
% =========================================================================
s = [];
if ~SIM_MODE
    fprintf('Opening %s  (FRAME_BYTES=%d)...\n', COM_PORT, FRAME_BYTES);
    s = serialport(COM_PORT, 115200);   % baud ignored by CDC; any value works
    s.Timeout = 5;
    flush(s);
    fprintf('Port open. Streaming...\n');
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
        [frame_data, seq, ok] = read_frame(s, N_CH, N_SAMP, HDR_BYTES, MAGIC);
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

    % --- DOA estimate ----------------------------------------------------
    [az, el] = doa_from_lags(lags_samp, M_pinv, Fs, C_MPS);

    % --- Update history ---------------------------------------------------
    hist_ptr = mod(hist_ptr, MAX_HIST) + 1;
    az_hist(hist_ptr) = az;
    el_hist(hist_ptr) = el;

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
        set(h_wfront(w), 'XData', [px-dx, px+dx], 'YData', [py-dy, py+dy]);
    end

    % --- Update DOA arrow ------------------------------------------------
    arr_len = 50;   % mm
    set(h_arrow, 'UData', arr_len*cosd(az), 'VData', arr_len*sind(az));
    set(h_doatxt, 'String', sprintf('az: %.1f°   el: %.1f°', az, el));

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

function [data, seq, ok] = read_frame(s, N_CH, N_SAMP, HDR_BYTES, MAGIC)
% Read and sync one raw frame from the serial port.
% Returns data (N_CH×N_SAMP int32), seq, and ok flag.
    data = []; seq = 0; ok = false;

    % Sync: slide 4-byte window until magic matches
    buf = read(s, 4, 'uint8');
    for attempt = 1:60000
        if isequal(buf, MAGIC), break; end
        buf = [buf(2:end), read(s, 1, 'uint8')];
        if attempt == 60000
            warning('stm32_mic_array:sync', 'Cannot find magic RAW1 after 60000 bytes.');
            return;
        end
    end

    % Header: 8 remaining bytes (seq + nch + nsamp_lo + nsamp_hi + fmt)
    hdr   = read(s, HDR_BYTES - 4, 'uint8');
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

    % Payload: N_CH*N_SAMP int32 values (little-endian, native on x86)
    raw  = read(s, N_CH * N_SAMP, 'int32');   % (N_CH*N_SAMP × 1)
    % C layout: row-major [N_CH][N_SAMP] → ch0 first, ch1 next, ...
    data = reshape(raw, [N_SAMP, N_CH])';      % (N_CH × N_SAMP)
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


function [az, el] = doa_from_lags(lags_samp, M_pinv, Fs, C)
% Least-squares DOA from 7 TDOA lags (mic0 vs mic1..7).
% Mirrors STM32 DOA_Compute().
    lag_m = double(lags_samp) * C / Fs;   % (7×1) path-length differences (m)
    u     = M_pinv * lag_m(:);            % (2×1) direction cosines estimate
    smag  = norm(u);
    if smag > 1, u = u / smag; smag = 1; end
    az = atan2d(u(2), u(1));             % degrees, 0=+x, CCW
    el = acosd(min(smag, 1.0));          % 0=in-plane, 90=overhead
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
