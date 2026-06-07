%% doa_validation.m
% Kiểm chứng thuật toán GCC-PHAT + LS-DOA cho mảng mic UCA 8 kênh.
% Mô phỏng sóng phẳng tới theo góc định trước, sau đó so sánh kết quả
% ước lượng với giá trị thực. Thuật toán hoàn toàn mirror code STM32.
%
% Chạy từng Section (Ctrl+Enter) hoặc toàn bộ script (F5).
%
% Sections:
%   1. Cấu hình và hình học mảng
%   2. Mô phỏng một nguồn âm + animation sóng phẳng
%   3. GCC-PHAT + hiển thị tương quan
%   4. Ước lượng DOA và so sánh với thực tế
%   5. Quét azimuth 0°–355° (kiểm tra toàn bộ góc)
%   6. Phân tích độ nhạy SNR

%% =========================================================================
%  1. Cấu hình và hình học mảng
% =========================================================================
clear; clc; close all;

Fs    = 16000;      % Hz — phải khớp STM32
N     = 1024;       % FFT/frame size — phải khớp STM32
R_M   = 0.040;      % bán kính UCA (m)
C_MPS = 343.0;      % tốc độ âm thanh (m/s)
N_CH  = 8;

% Bảng góc channel — khớp hoàn toàn với mic_pos[][] trong main.c
% pair p: ch_L = p*2 tại p*45°, ch_R = p*2+1 tại p*45+180°
ANG_DEG = [0, 180, 45, 225, 90, 270, 135, 315];   % (1×8)
mic_x   = R_M * cosd(ANG_DEG);                      % (1×8) m
mic_y   = R_M * sind(ANG_DEG);
mic_pos = [mic_x(:), mic_y(:)];                     % (8×2) m

% Pseudo-inverse DOA — mirror STM32 DOA_Init()
% D[k] = mic_pos[k+1] - mic_pos[0],  k=0..6  →  (7×2)
% u = M_pinv * (lag_samp * C/Fs)  →  2D direction cosines
D_mat  = mic_pos(2:end,:) - mic_pos(1,:);           % (7×2)
M_pinv = (D_mat' * D_mat) \ D_mat';                 % (2×7)

MAX_TDOA_SAMP = 2 * R_M / C_MPS * Fs;   % max delay = diameter / c

fprintf('=== Array geometry ===\n');
fprintf('  UCA radius    : %.0f mm\n', R_M*1e3);
fprintf('  Max TDOA      : %.3f ms = %.2f samples\n', ...
        2*R_M/C_MPS*1e3, MAX_TDOA_SAMP);
fprintf('  Nyquist alias : TDOA < 0.5 sample → f < %.0f Hz is unambiguous\n', ...
        C_MPS / (2 * 2*R_M));
fprintf('\n  Ch  Angle    x(mm)   y(mm)\n');
for i = 1:N_CH
    fprintf('  ch%d  %3d°   %+6.1f  %+6.1f\n', ...
            i-1, ANG_DEG(i), mic_x(i)*1e3, mic_y(i)*1e3);
end

%% =========================================================================
%  2. Mô phỏng nguồn âm + Animation sóng phẳng
% =========================================================================
% --- Tham số nguồn (chỉnh ở đây để kiểm thử) ---
AZ_TRUE = 120;    % azimuth thực (độ), 0° = +x, CCW
EL_TRUE =  0.0;    % elevation thực (độ), 0 = trong mặt phẳng
SNR_DB  = 20;      % SNR (dB)
F_SRC   = 20000;    % tần số nguồn (Hz)

ux = cosd(AZ_TRUE) * cosd(EL_TRUE);   % direction cosines
uy = sind(AZ_TRUE) * cosd(EL_TRUE);

% Độ trễ truyền âm từng mic so với mic0 (sample, dấu tính đúng chiều)
delay_samp = zeros(N_CH, 1);
for i = 1:N_CH
    dx = mic_pos(i,1) - mic_pos(1,1);
    dy = mic_pos(i,2) - mic_pos(1,2);
    delay_samp(i) = -(dx*ux + dy*uy) / C_MPS * Fs;
end

fprintf('\n=== Simulation: az=%.1f°  el=%.1f°  f=%dHz  SNR=%ddB ===\n', ...
        AZ_TRUE, EL_TRUE, F_SRC, SNR_DB);
fprintf('  Delay relative to ch0 (samples):\n');
for i = 1:N_CH
    fprintf('    ch0 vs ch%d: %+.4f samples  (%+.3f µs)\n', ...
            i-1, delay_samp(i)-delay_samp(1), ...
            (delay_samp(i)-delay_samp(1))/Fs*1e6);
end

% --- Tạo tín hiệu ---
t_frame = (0:N-1) / Fs;                         % time axis một frame (s)
noise_amp = 10^(-SNR_DB/20);

mic_sig = zeros(N_CH, N);
for i = 1:N_CH
    mic_sig(i,:) = sin(2*pi * F_SRC * (t_frame - delay_samp(i)/Fs)) ...
                 + noise_amp * randn(1, N);
end

% --- Figure 1: Animation sóng phẳng ---
fig1 = figure('Name', 'Sóng phẳng tới mảng mic', ...
              'Position', [50 80 820 680], 'Color', [0.07 0.07 0.07]);

ax_arr = axes('Parent', fig1, 'Position', [0.07 0.38 0.57 0.57]);
hold(ax_arr,'on'); axis(ax_arr,'equal'); grid(ax_arr,'on');
set(ax_arr, 'Color',[0.1 0.1 0.1], 'XColor','w', 'YColor','w', ...
            'GridColor',[0.22 0.22 0.22], 'FontSize', 9);

% Vòng tròn UCA
th_c = linspace(0, 2*pi, 300);
plot(ax_arr, R_M*1e3*cos(th_c), R_M*1e3*sin(th_c), '--', ...
     'Color',[0.35 0.35 0.35], 'LineWidth', 0.8);

% Đường kính nối các cặp mic đối diện
pair_clr = [1 0.45 0.45; 0.45 1 0.45; 0.4 0.75 1; 1 0.8 0.25];
for p = 0:3
    chL = p*2+1;  chR = p*2+2;
    plot(ax_arr, mic_x([chL,chR])*1e3, mic_y([chL,chR])*1e3, ...
         '-', 'Color',[pair_clr(p+1,:) 0.3], 'LineWidth', 1.2);
end

% Mic (sẽ đổi màu khi sóng qua)
h_mics = scatter(ax_arr, mic_x*1e3, mic_y*1e3, 130, ...
                 repmat([0.3 0.7 1], N_CH, 1), 'filled', ...
                 'MarkerEdgeColor','w', 'LineWidth', 0.8);
for i = 1:N_CH
    lr = (R_M + 0.014)*1e3;
    text(ax_arr, lr*cosd(ANG_DEG(i)), lr*sind(ANG_DEG(i)), ...
         sprintf('ch%d', i-1), 'Color','w', 'FontSize',7.5, ...
         'HorizontalAlignment','center');
end

% Mũi tên hướng nguồn
quiver(ax_arr, 0, 0, 70*ux, 70*uy, 0, ...
       'Color',[1 0.3 0.3], 'LineWidth', 2.2, 'MaxHeadSize', 0.5);
text(ax_arr, 76*ux, 76*uy, sprintf('Nguồn\naz=%.1f°', AZ_TRUE), ...
     'Color',[1 0.55 0.55], 'FontSize', 8.5, 'HorizontalAlignment','center');

% Các đường sóng (9 đường song song)
N_WF = 9;
h_wf = gobjects(N_WF, 1);
for w = 1:N_WF
    h_wf(w) = plot(ax_arr, [0 0],[0 0], 'Color',[0.25 0.85 1 0], 'LineWidth', 1.4);
end

xlim(ax_arr, [-95 115]); ylim(ax_arr, [-80 80]);
xlabel(ax_arr, 'x (mm)', 'Color','w');
ylabel(ax_arr, 'y (mm)', 'Color','w');
h_arr_title = title(ax_arr, 'Sóng phẳng truyền qua mảng mic', ...
                    'Color','w', 'FontSize',10);

% Subplot waveform nhỏ bên phải (hiển thị trễ)
ax_wav = axes('Parent', fig1, 'Position', [0.67 0.38 0.30 0.57]);
hold(ax_wav,'on'); grid(ax_wav,'on');
set(ax_wav,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.22 0.22 0.22],'FontSize',8);
t_show_ms = t_frame(1:min(N, round(Fs*0.006))) * 1e3;   % hiển thị 6ms đầu
n_show    = length(t_show_ms);
WOFF = 2.2;
h_wav_lines = gobjects(N_CH, 1);
for i = 1:N_CH
    h_wav_lines(i) = plot(ax_wav, t_show_ms, ...
                          zeros(1,n_show) + (N_CH-i)*WOFF, ...
                          'Color', pair_clr(ceil(i/2),:), 'LineWidth', 0.9);
end
xlim(ax_wav, [0 t_show_ms(end)]);
ylim(ax_wav, [-1.2 (N_CH-0.5)*WOFF]);
yticks(ax_wav, (0:N_CH-1)*WOFF); yticklabels(ax_wav, flip(arrayfun(@(i) ...
    sprintf('ch%d',i), 0:N_CH-1,'uni',0)));
xlabel(ax_wav,'t (ms)','Color','w');
title(ax_wav,'Tín hiệu từng mic','Color','w','FontSize',9);

% Subplot thứ tự hit bên dưới
ax_ord = axes('Parent', fig1, 'Position', [0.07 0.07 0.87 0.26]);
hold(ax_ord,'on'); grid(ax_ord,'on');
set(ax_ord,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.22 0.22 0.22],'FontSize',8);
proj = mic_x * ux + mic_y * uy;   % (1×8) projection along source direction

% --- Chạy animation ---
p_start  = max(proj) + R_M * 1.5;
p_end    = min(proj) - R_M * 1.5;
p_frames = linspace(p_start, p_end, 90);

% Khoảng cách giữa các đường sóng = lambda/2
lambda    = C_MPS / F_SRC;
wf_gaps   = (0:N_WF-1) * lambda;

hit_time_ms = nan(1, N_CH);
t_elapsed = 0;

for fi = 1:length(p_frames)
    p_now = p_frames(fi);
    t_elapsed = (p_start - p_now) / C_MPS * 1e3;   % ms từ lúc bắt đầu

    % Cập nhật các đường sóng
    for w = 1:N_WF
        p_wf = p_now + wf_gaps(w);   % vị trí đường sóng thứ w
        s_mm = linspace(-110, 110, 2) / 1e3;   % parametric (m)
        px   = (p_wf*ux + s_mm*(-uy)) * 1e3;
        py   = (p_wf*uy + s_mm*( ux)) * 1e3;
        % fade alpha theo khoảng cách từ tâm array
        d_center = abs(p_wf - mean(proj));
        alpha = max(0, 1 - d_center / (R_M * 3.5));
        set(h_wf(w), 'XData', px, 'YData', py, ...
                     'Color', [0.25 0.85 1 min(alpha*0.9, 0.88)]);
    end

    % Đổi màu mic khi sóng vừa qua (proj(i) >= p_now)
    mic_clr = repmat([0.3 0.7 1], N_CH, 1);
    for i = 1:N_CH
        if proj(i) >= p_now
            mic_clr(i,:) = [1 0.85 0.2];   % vàng = đã bị hit
            if isnan(hit_time_ms(i))
                hit_time_ms(i) = t_elapsed;
            end
        end
    end
    h_mics.CData = mic_clr;

    % Cập nhật waveform (hiển thị dần theo thời gian mô phỏng)
    n_show_now = min(n_show, max(1, round(t_elapsed/1e3*Fs)));
    for i = 1:N_CH
        sig_i = mic_sig(i, 1:n_show);
        sig_i(n_show_now+1:end) = 0;   % ẩn phần chưa đến
        set(h_wav_lines(i), 'YData', sig_i*0.8 + (N_CH-i)*WOFF);
    end

    set(h_arr_title, 'String', ...
        sprintf('t = %.2f ms  |  Wavefront pos = %.1f mm', t_elapsed, p_now*1e3));
    drawnow limitrate;
    pause(0.025);
end

% Vẽ thứ tự hit
[~, hit_order] = sort(proj, 'descend');
colors_ord = jet(N_CH);
for rank = 1:N_CH
    i = hit_order(rank);
    bar(ax_ord, rank, delay_samp(i) - delay_samp(hit_order(1)), ...
        'FaceColor', colors_ord(rank,:), 'EdgeColor','none');
    text(ax_ord, rank, (delay_samp(i)-delay_samp(hit_order(1)))*0.5, ...
         sprintf('ch%d\n(%.2fs)', i-1, delay_samp(i)-delay_samp(hit_order(1))), ...
         'HorizontalAlignment','center', 'Color','w', 'FontSize',7);
end
xticks(ax_ord,1:N_CH);
xticklabels(ax_ord, arrayfun(@(r) sprintf('rank %d',r), 1:N_CH,'uni',0));
ylabel(ax_ord, 'Delay vs ch0 (samples)', 'Color','w');
title(ax_ord, 'Thứ tự mic bị hit (so với mic đầu tiên)', 'Color','w','FontSize',9);

%% =========================================================================
%  3. GCC-PHAT: tính và vẽ tương quan ch0 vs ch1..7
% =========================================================================
N_PAIRS    = N_CH - 1;
lags_est   = zeros(N_PAIRS, 1);
gcc_all    = zeros(N_PAIRS, N);
true_lags  = delay_samp(2:end) - delay_samp(1);

for k = 1:N_PAIRS
    [gcc_all(k,:), lags_est(k)] = gcc_phat(mic_sig(1,:), mic_sig(k+1,:), N);
end

fprintf('\n=== GCC-PHAT ===\n');
fprintf('  %-10s  %-14s  %-14s  %-10s\n', 'Pair','True (samp)','Est (samp)','Error');
for k = 1:N_PAIRS
    fprintf('  ch0↔ch%d    %+8.4f      %+8.4f      %+.4f\n', ...
            k, true_lags(k), lags_est(k), lags_est(k)-true_lags(k));
end

max_lag_us   = ceil(2*R_M/C_MPS * 1.5 * 1e6);
lag_us_axis  = (-N/2 : N/2-1) / Fs * 1e6;
vis_mask     = abs(lag_us_axis) <= max_lag_us;

fig2 = figure('Name', 'GCC-PHAT', 'Position',[890 80 640 760], ...
              'Color',[0.07 0.07 0.07]);
for k = 1:N_PAIRS
    ax = subplot(N_PAIRS, 1, k, 'Parent', fig2);
    set(ax,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.2 0.2 0.2],'FontSize',7.5);
    hold(ax,'on'); grid(ax,'on');

    plot(ax, lag_us_axis(vis_mask), gcc_all(k,vis_mask), ...
         'Color',[0.4 0.75 1], 'LineWidth', 0.9);

    % True lag
    xline(ax, true_lags(k)/Fs*1e6, '--', 'Color',[0.3 1 0.3], 'LineWidth', 1.5);
    % Estimated lag
    xline(ax, lags_est(k)/Fs*1e6,  '-',  'Color',[1 0.35 0.35], 'LineWidth', 1.8);

    xlim(ax, [-max_lag_us max_lag_us]);
    ylabel(ax, sprintf('ch0↔ch%d', k), 'Color','w', 'FontSize',7);
    if k == 1
        title(ax, sprintf('GCC-PHAT  az=%.1f°  SNR=%ddB  (──red=est, --green=true)', ...
              AZ_TRUE, SNR_DB), 'Color','w', 'FontSize',9);
    end
    if k == N_PAIRS
        xlabel(ax, 'Lag (µs)', 'Color','w', 'FontSize',8);
    end
end

%% =========================================================================
%  4. DOA Estimation — so sánh với giá trị thực
% =========================================================================
[az_est, el_est] = doa_ls(lags_est, M_pinv, Fs, C_MPS);
az_err = mod(az_est - AZ_TRUE + 180, 360) - 180;
el_err = el_est - EL_TRUE;

fprintf('\n=== DOA result ===\n');
fprintf('  True :     az = %.3f°   el = %.3f°\n', AZ_TRUE, EL_TRUE);
fprintf('  Estimated: az = %.3f°   el = %.3f°\n', az_est, el_est);
fprintf('  Error:     az = %+.3f°  el = %+.3f°\n', az_err, el_err);

% Polar figure
fig3 = figure('Name', 'DOA result', 'Position',[50 50 500 500], ...
              'Color',[0.07 0.07 0.07]);
pax = polaraxes('Parent', fig3);
set(pax,'Color',[0.1 0.1 0.1],'GridColor',[0.35 0.35 0.35], ...
        'ThetaDir','counterclockwise','ThetaZeroLocation','right', ...
        'RColor','w','ThetaColor','w','FontSize',9);
pax.RLim = [0 1.1];  pax.RTick = [0.5 1.0];
pax.RTickLabel = {'60° el','0° el'};
hold(pax,'on');

% Vẽ các mic lên polar
for i = 1:N_CH
    polarscatter(pax, deg2rad(ANG_DEG(i)), 1.0, 60, ...
                 pair_clr(ceil(i/2),:), 'filled', 'MarkerEdgeColor','w');
    text(pax, deg2rad(ANG_DEG(i)), 1.15, sprintf('ch%d',i-1), ...
         'Color','w','FontSize',7,'HorizontalAlignment','center');
end

% True DOA
polarscatter(pax, deg2rad(AZ_TRUE), cosd(EL_TRUE), 200, [0.3 1 0.3], ...
             'filled', 'Marker','p', 'MarkerEdgeColor','w', 'LineWidth', 1);

% Estimated DOA
polarscatter(pax, deg2rad(az_est), cosd(el_est), 160, [1 0.35 0.35], ...
             'filled', 'Marker','d', 'MarkerEdgeColor','w', 'LineWidth', 1);

legend(pax, {'Mics','','','','','','','','True DOA','Estimated DOA'}, ...
       'TextColor','w','Color',[0.15 0.15 0.15],'FontSize',8, ...
       'Location','southoutside','NumColumns',2);
title(pax, sprintf('DOA: az_{true}=%.1f°  az_{est}=%.1f°  err=%+.2f°', ...
      AZ_TRUE, az_est, az_err), 'Color','w','FontSize',10);

%% =========================================================================
%  5. Quét azimuth 0°–355° — kiểm tra độ chính xác toàn bộ góc
% =========================================================================
fprintf('\n=== Azimuth sweep (0:5:355°, el=%.0f°, SNR=%ddB) ===\n', EL_TRUE, SNR_DB);
az_sweep   = 0:5:355;
az_out     = zeros(size(az_sweep));
el_out     = zeros(size(az_sweep));
lags_sweep = zeros(N_PAIRS, 1);

for ti = 1:length(az_sweep)
    uxt = cosd(az_sweep(ti));  uyt = sind(az_sweep(ti));
    d_t = zeros(N_CH,1);
    for i = 1:N_CH
        dx = mic_pos(i,1)-mic_pos(1,1);  dy = mic_pos(i,2)-mic_pos(1,2);
        d_t(i) = -(dx*uxt + dy*uyt) / C_MPS * Fs;
    end
    s_t = zeros(N_CH,N);
    for i = 1:N_CH
        s_t(i,:) = sin(2*pi*F_SRC*(t_frame - d_t(i)/Fs)) ...
                 + noise_amp*randn(1,N);
    end
    for k = 1:N_PAIRS
        [~, lags_sweep(k)] = gcc_phat(s_t(1,:), s_t(k+1,:), N);
    end
    [az_out(ti), el_out(ti)] = doa_ls(lags_sweep, M_pinv, Fs, C_MPS);
end

az_err_sweep = mod(az_out - az_sweep + 180, 360) - 180;

fig4 = figure('Name', 'Azimuth sweep validation', ...
              'Position',[50 50 1100 480], 'Color',[0.07 0.07 0.07]);

ax_s1 = subplot(1,2,1, 'Parent', fig4);
hold(ax_s1,'on'); grid(ax_s1,'on');
set(ax_s1,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
          'GridColor',[0.2 0.2 0.2],'FontSize',9);
plot(ax_s1, az_sweep, az_sweep, '--', 'Color',[0.45 0.45 0.45], 'LineWidth',1.2);
plot(ax_s1, az_sweep, mod(az_out,360), 'c.-', 'LineWidth',1.2, 'MarkerSize',10);
xlabel(ax_s1,'Azimuth thực (°)','Color','w');
ylabel(ax_s1,'Azimuth ước lượng (°)','Color','w');
title(ax_s1,'Ước lượng vs Thực tế','Color','w','FontSize',10);
legend(ax_s1,{'Ideal (y=x)','GCC-PHAT+LS'}, ...
       'TextColor','w','Color',[0.15 0.15 0.15]);
xlim(ax_s1,[0 360]); ylim(ax_s1,[0 360]);

ax_s2 = subplot(1,2,2, 'Parent', fig4);
hold(ax_s2,'on'); grid(ax_s2,'on');
set(ax_s2,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
          'GridColor',[0.2 0.2 0.2],'FontSize',9);
bar(ax_s2, az_sweep, az_err_sweep, 1, 'FaceColor',[0.4 0.7 1], 'EdgeColor','none');
yline(ax_s2,  2, '--','Color',[0.9 0.5 0.5],'LineWidth',1.2,'Label','+2°');
yline(ax_s2, -2, '--','Color',[0.9 0.5 0.5],'LineWidth',1.2,'Label','−2°');
yline(ax_s2,  0, '-', 'Color',[0.5 0.5 0.5],'LineWidth',0.8);
xlabel(ax_s2,'Azimuth thực (°)','Color','w');
ylabel(ax_s2,'Sai số (°)','Color','w');
rms_err = rms(az_err_sweep);
max_err = max(abs(az_err_sweep));
title(ax_s2, sprintf('Sai số DOA  [RMS=%.2f°  Max=%.2f°  SNR=%ddB]', ...
      rms_err, max_err, SNR_DB), 'Color','w','FontSize',10);
xlim(ax_s2,[0 360]);

fprintf('  RMS sai số: %.3f°\n', rms_err);
fprintf('  Max sai số: %.3f°\n', max_err);

%% =========================================================================
%  6. Phân tích độ nhạy SNR (az=45°, 50 trials mỗi điểm)
% =========================================================================
fprintf('\n=== SNR sensitivity (az=45°, %d trials/point) ===\n', 50);
snr_range  = -10:5:40;
rms_vs_snr = zeros(size(snr_range));
N_TRIALS   = 50;

for si = 1:length(snr_range)
    n_amp = 10^(-snr_range(si)/20);
    errs  = zeros(1, N_TRIALS);
    uxt = cosd(45);  uyt = sind(45);
    d_t = zeros(N_CH,1);
    for i = 1:N_CH
        dx=mic_pos(i,1)-mic_pos(1,1); dy=mic_pos(i,2)-mic_pos(1,2);
        d_t(i)=-(dx*uxt+dy*uyt)/C_MPS*Fs;
    end
    for tr = 1:N_TRIALS
        s_t=zeros(N_CH,N);
        for i=1:N_CH
            s_t(i,:)=sin(2*pi*F_SRC*(t_frame-d_t(i)/Fs))+n_amp*randn(1,N);
        end
        lgs=zeros(N_PAIRS,1);
        for k=1:N_PAIRS, [~,lgs(k)]=gcc_phat(s_t(1,:),s_t(k+1,:),N); end
        [az_r,~]=doa_ls(lgs,M_pinv,Fs,C_MPS);
        errs(tr)=mod(az_r-45+180,360)-180;
    end
    rms_vs_snr(si)=rms(errs);
    fprintf('  SNR=%3d dB → RMS = %.2f°\n', snr_range(si), rms_vs_snr(si));
end

fig5 = figure('Name', 'SNR Sensitivity', 'Position',[600 50 600 420], ...
              'Color',[0.07 0.07 0.07]);
ax_snr = axes('Parent', fig5);
hold(ax_snr,'on'); grid(ax_snr,'on');
set(ax_snr,'Color',[0.1 0.1 0.1],'XColor','w','YColor','w', ...
           'GridColor',[0.2 0.2 0.2],'FontSize',10,'YScale','log');
plot(ax_snr, snr_range, rms_vs_snr, 'c.-', 'LineWidth', 2, 'MarkerSize', 14);
yline(ax_snr, 1, '--','Color',[0.8 0.5 0.5],'LineWidth',1.2,'Label','1°');
yline(ax_snr, 5, '--','Color',[0.6 0.4 0.4],'LineWidth',1.2,'Label','5°');
xline(ax_snr, SNR_DB, '--','Color',[0.5 0.8 0.5],'LineWidth',1.2, ...
      'Label',sprintf('Sim SNR=%ddB',SNR_DB));
xlabel(ax_snr, 'SNR (dB)', 'Color','w');
ylabel(ax_snr, 'RMS Sai số azimuth (°)', 'Color','w');
title(ax_snr, sprintf('Độ nhạy SNR  (az=45°, f=%dHz, UCA d=80mm, %d trials)', ...
      F_SRC, N_TRIALS), 'Color','w', 'FontSize',10);

fprintf('\n=== Hoàn tất ===\n');

%% =========================================================================
%  Local functions
% =========================================================================

function [corr_shift, lag_samp] = gcc_phat(x, y, N)
% GCC-PHAT với nội suy parabol sub-sample.
% Mirror hoàn toàn STM32 TASK-11.
    X = fft(double(x), N);
    Y = fft(double(y), N);
    G = X .* conj(Y);
    G = G ./ max(abs(G), 1e-10);        % PHAT whitening
    corr_shift = real(ifft(G));
    corr_shift = fftshift(corr_shift);
    [~, idx] = max(corr_shift);
    % Parabolic interpolation (mirror STM32)
    if idx > 1 && idx < N
        ym1 = corr_shift(idx-1);
        y0  = corr_shift(idx);
        yp1 = corr_shift(idx+1);
        denom = 2*(2*y0 - ym1 - yp1);
        if abs(denom) > 1e-10
            frac = (yp1 - ym1) / denom;
        else
            frac = 0;
        end
    else
        frac = 0;
    end
    lag_samp = (idx - N/2 - 1) + frac;
end


function [az, el] = doa_ls(lags_samp, M_pinv, Fs, C)
% Least-squares DOA. Mirror STM32 DOA_Compute().
    lag_m = double(lags_samp) * C / Fs;   % path diff (m)
    u     = M_pinv * lag_m(:);            % 2D direction estimate
    smag  = norm(u);
    if smag > 1, u = u / smag;  smag = 1; end
    az = atan2d(u(2), u(1));
    el = acosd(min(smag, 1.0));
end
