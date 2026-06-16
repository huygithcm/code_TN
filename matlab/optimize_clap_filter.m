%% optimize_clap_filter.m
% Phan tich claps_record.wav de TOI UU bo loc clap cho firmware:
%   - Do muc nang luong frame (mirror firmware: N=1024, sum of squares)
%   - Mo phong cong onset (level vs nen EMA) va quet CLAP_RATIO
%   - So sanh pho clap vs nen -> co nen them highpass/bandpass khong
%   - Goi y tham so: CLAP_RATIO, CLAP_ABS_MIN, (tuy chon) tan so cat
%
% Chay:  optimize_clap_filter

function optimize_clap_filter

    WAV = 'claps_record.wav';
    N   = 1024;                  % frame = AUDIO_BLOCK_SAMPLES
    BG_ALPHA = 0.10;             % EMA nen (giong firmware)

    [x, Fs] = audioread(WAV);
    x = x(:,1);                  % mono
    fprintf('Doc %s: %d mau, %.1f s @ %d Hz\n', WAV, numel(x), numel(x)/Fs, Fs);

    % ===== 1) Muc nang luong tung frame ===============================
    nfr   = floor(numel(x)/N);
    level = zeros(nfr,1);
    tfr   = (0:nfr-1)*N/Fs;
    for f = 1:nfr
        seg = x((f-1)*N + (1:N));
        level(f) = sum(seg.^2);
    end
    bg_floor = median(level);
    pk       = max(level);
    fprintf('\nLevel: nen(median)=%.4g  dinh(max)=%.4g  ti so=%.0fx\n', ...
            bg_floor, pk, pk/max(bg_floor,1e-12));

    % ===== 2) Mo phong cong onset + quet CLAP_RATIO ===================
    % Voi moi RATIO, dem so frame clap phat hien va nhom thanh "su kien clap"
    % (cac frame clap lien nhau = 1 su kien). Chon RATIO bat duoc cac clap that
    % ma khong sinh qua nhieu su kien rac.
    ratios = [3 4 5 6 8 10 15 20 30];
    fprintf('\n=== Quet CLAP_RATIO (CLAP_ABS_MIN = 3x nen = %.4g) ===\n', 3*bg_floor);
    abs_min = 3*bg_floor;
    for r = ratios
        [nev, nframes] = count_claps(level, r, abs_min, BG_ALPHA);
        fprintf('  RATIO=%2d -> %d su kien clap (%d frame)\n', r, nev, nframes);
    end

    % ===== 3) So sanh pho clap vs nen =================================
    % Lay frame manh nhat (clap) va mot frame yen tinh (nen) de so pho.
    [~, fc] = max(level);                      % frame clap
    qframes = find(level < 2*bg_floor);        % cac frame yen
    fq = qframes(round(numel(qframes)/2));     % mot frame nen
    seg_c = x((fc-1)*N + (1:N)) .* hann(N);
    seg_q = x((fq-1)*N + (1:N)) .* hann(N);
    fax = (0:N/2-1)*Fs/N;
    Pc = abs(fft(seg_c)).^2; Pc = Pc(1:N/2);
    Pq = abs(fft(seg_q)).^2; Pq = Pq(1:N/2);
    Pc = Pc/max(Pc); Pq = Pq/max(Pq+1e-20);

    % nang luong clap theo bang tan (de quyet dinh highpass)
    bands = [0 500; 500 1000; 1000 2000; 2000 4000; 4000 8000];
    fprintf('\n=== Phan bo nang luong CLAP theo dai tan ===\n');
    Ptot = sum(Pc);
    for b = 1:size(bands,1)
        m = fax >= bands(b,1) & fax < bands(b,2);
        fprintf('  %4d-%4d Hz: %5.1f%%\n', bands(b,1), bands(b,2), 100*sum(Pc(m))/Ptot);
    end

    % ===== 4) Goi y tham so ===========================================
    % RATIO: ~1/2 ti so dinh/nen, ke ca de bat clap nho, gioi han 4..12
    ratio_sug = min(max(round(0.4 * pk/max(bg_floor,1e-12)), 4), 12);
    fprintf('\n=== GOI Y FIRMWARE (DOA_Task) ===\n');
    fprintf('  CLAP_ABS_MIN = %.4g   (3x nen median)\n', abs_min);
    fprintf('  CLAP_RATIO   = %d\n', ratio_sug);

    % ===== 5) Ve do thi ===============================================
    figure('Name','Clap filter optimization','Color','w','Position',[80 80 900 600]);
    subplot(2,2,[1 2]);
    plot(tfr, level,'LineWidth',1); grid on; hold on;
    yline(abs_min,'--r','CLAP\_ABS\_MIN');
    [nev,~] = count_claps(level, ratio_sug, abs_min, BG_ALPHA);
    title(sprintf('Level/frame - RATIO=%d phat hien %d clap', ratio_sug, nev));
    xlabel('t (s)'); ylabel('\Sigma x^2');

    subplot(2,2,3);
    semilogx(fax, 10*log10(Pc+1e-12),'r','LineWidth',1); hold on; grid on;
    semilogx(fax, 10*log10(Pq+1e-12),'b','LineWidth',1);
    legend('clap','nen','Location','southwest');
    xlabel('Hz'); ylabel('dB (chuan hoa)'); title('Pho clap vs nen');
    xlim([50 Fs/2]);

    subplot(2,2,4);
    plot((0:N-1)/Fs*1e3, x((fc-1)*N + (1:N)),'r'); grid on;
    xlabel('ms trong frame'); ylabel('bien do'); title('Dang song 1 clap');

    print(gcf,'clap_filter_opt.png','-dpng','-r100');
    fprintf('\nDa luu do thi: clap_filter_opt.png\n');
end

% Dem su kien clap: mo phong cong onset giong firmware.
function [n_events, n_frames] = count_claps(level, ratio, abs_min, alpha)
    bg = abs_min; prev = false; n_events = 0; n_frames = 0;
    for f = 1:numel(level)
        is_clap = (level(f) > ratio*bg) && (level(f) > abs_min);
        if ~is_clap, bg = bg + alpha*(level(f)-bg); end
        if is_clap
            n_frames = n_frames + 1;
            if ~prev, n_events = n_events + 1; end
        end
        prev = is_clap;
    end
end
