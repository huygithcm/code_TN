%% record_claps.m
% Ghi 20 giay am thanh tu micro may tinh (de vo tay), luu WAV, va phan tich
% muc nang luong theo frame (giong firmware) de can nguong bo loc clap.
%
% Cach dung:
%   1) Chay:  record_claps
%   2) Cho dem nguoc roi VO TAY vai cai (cach nhau ~1-2 giay), xen ke noi/im lang.
%   3) Script luu 'claps_record.wav' + ve do thi + goi y nguong CLAP_*.
%
% Tham so khop firmware: Fs=16kHz, frame N=1024 (64 ms/frame).

function record_claps

    Fs   = 16000;     % Hz - khop sample rate firmware
    SECS = 20;        % thoi luong ghi
    N    = 1024;      % kich thuoc frame (giong AUDIO_BLOCK_SAMPLES)
    WAV  = 'claps_record.wav';

    % ----- Ghi am -------------------------------------------------------
    rec = audiorecorder(Fs, 16, 1);     % 16-bit, mono
    fprintf('Chuan bi ghi %d giay @ %d Hz...\n', SECS, Fs);
    for k = 3:-1:1
        fprintf('  bat dau sau %d...\n', k); pause(1);
    end
    fprintf('>>> GHI! Vo tay vai cai, xen ke noi/im lang. <<<\n');
    recordblocking(rec, SECS);
    fprintf('Xong ghi.\n');

    x = getaudiodata(rec);              % (L x 1), float [-1,1]
    audiowrite(WAV, x, Fs);
    fprintf('Da luu: %s  (%d mau, %.1f s)\n', WAV, numel(x), numel(x)/Fs);

    % ----- Phan tich nang luong theo frame (mirror firmware level) ------
    analyze_levels(x, Fs, N);
end

function analyze_levels(x, Fs, N)
    x = x(:);
    nfr   = floor(numel(x)/N);
    level = zeros(nfr,1);               % sum of squares moi frame (= res.level)
    tfr   = (0:nfr-1) * N / Fs;         % thoi gian moi frame (s)
    for f = 1:nfr
        seg = x((f-1)*N + (1:N));
        level(f) = sum(seg.^2);
    end

    % nen nhieu = phan vi thap; clap = dinh cao
    bg   = median(level);                       % uoc luong nen
    pk   = max(level);
    p90  = prctile(level, 90);
    fprintf('\n=== Phan tich muc nang luong frame (N=%d) ===\n', N);
    fprintf('  nen (median)   : %.4g\n', bg);
    fprintf('  90%% percentile : %.4g\n', p90);
    fprintf('  dinh (max)     : %.4g\n', pk);
    fprintf('  ti so dinh/nen  : %.1fx\n', pk/max(bg,1e-9));

    % goi y nguong cho firmware
    clap_abs = bg + 0.3*(pk - bg);              % giua nen va dinh
    clap_ratio = max(4, 0.5 * pk/max(bg,1e-9)); % ~1/2 ti so dinh/nen, toi thieu 4
    fprintf('\n  --> Goi y firmware (DOA_Task):\n');
    fprintf('      CLAP_ABS_MIN = %.3g\n', clap_abs);
    fprintf('      CLAP_RATIO   = %.1f\n', clap_ratio);
    fprintf('  (Luu y: thang firmware dung mic_data 24-bit chuan hoa, co the\n');
    fprintf('   khac thang micro PC - dung de tham khao ti le dinh/nen la chinh.)\n\n');

    % ----- Ve do thi ----------------------------------------------------
    figure('Name','Clap recording analysis','Color','w');
    subplot(2,1,1);
    plot((0:numel(x)-1)/Fs, x); grid on;
    xlabel('t (s)'); ylabel('bien do'); title('Waveform 20 s (vo tay)');
    xlim([0 numel(x)/Fs]);

    subplot(2,1,2);
    plot(tfr, level, 'LineWidth', 1); grid on; hold on;
    yline(bg,       '--g', 'nen');
    yline(clap_abs, '--r', 'CLAP\_ABS\_MIN goi y');
    xlabel('t (s)'); ylabel('level (\Sigma x^2 / frame)');
    title('Nang luong theo frame - dinh = clap');
    xlim([0 tfr(end)]);

    print(gcf, 'claps_analysis.png', '-dpng', '-r100');
    fprintf('Da luu do thi: claps_analysis.png\n');
end
