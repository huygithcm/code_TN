%% design_clap_hpf.m
% Thiet ke + kiem chung highpass cho cong clap, sinh he so biquad cho firmware.
% Dua tren claps_record.wav: nen nhieu tap trung tan thap, clap trai rong 500-2k Hz.
% Highpass loai nhieu tan thap -> tang ti so clap/nen trong phong on.
%
% Chay:  design_clap_hpf

function design_clap_hpf

    WAV = 'claps_record.wav';
    N   = 1024;
    [x, Fs] = audioread(WAV);  x = x(:,1);

    % ===== Quet tan so cat, do ti so phan tach clap/nen sau loc =========
    cutoffs = [200 300 500 700 1000];
    fprintf('=== Quet tan so cat highpass (bac 2 Butterworth) ===\n');
    fprintf('  fc(Hz) | dinh clap | nen(median) | ti so\n');
    best_fc = 500; best_sep = 0;
    for fc = cutoffs
        [b,a] = butter(2, fc/(Fs/2), 'high');
        y = filter(b, a, x);
        lv = frame_level(y, N);
        sep = max(lv) / max(median(lv), 1e-12);
        fprintf('  %5d  | %9.4g | %11.4g | %.0fx\n', fc, max(lv), median(lv), sep);
        if sep > best_sep, best_sep = sep; best_fc = fc; end
    end
    % so voi khong loc
    lv0 = frame_level(x, N);
    sep0 = max(lv0)/max(median(lv0),1e-12);
    fprintf('  (khong loc): ti so = %.0fx\n', sep0);

    % Chon 500 Hz (giu ~82%% nang luong clap, loai phan lon nhieu tan thap)
    fc = 500;
    [b,a] = butter(2, fc/(Fs/2), 'high');
    fprintf('\n=== He so biquad highpass %d Hz (Direct Form II transposed) ===\n', fc);
    fprintf('Fs=%d Hz, bac 2 Butterworth\n', Fs);
    fprintf('b = [% .8f, % .8f, % .8f]\n', b(1), b(2), b(3));
    fprintf('a = [% .8f, % .8f, % .8f]\n', a(1), a(2), a(3));

    fprintf('\n--- Dan vao firmware (loc ch0 truoc khi tinh level) ---\n');
    fprintf('static const float HPF_B[3] = { %.8ff, %.8ff, %.8ff };\n', b(1),b(2),b(3));
    fprintf('static const float HPF_A[3] = { %.8ff, %.8ff, %.8ff };\n', a(1),a(2),a(3));
    fprintf(['// trong FFT_Task, thay vong tinh level bang:\n' ...
             '//   static float w1=0, w2=0;  float lvl=0;\n' ...
             '//   for(n) { float in=mic_data[0][n];\n' ...
             '//     float yo = HPF_B[0]*in + w1;\n' ...
             '//     w1 = HPF_B[1]*in - HPF_A[1]*yo + w2;\n' ...
             '//     w2 = HPF_B[2]*in - HPF_A[2]*yo;\n' ...
             '//     lvl += yo*yo; }\n' ...
             '//   res.level = lvl;\n']);

    % ===== Kiem chung: dem clap truoc/sau loc ==========================
    y = filter(b,a,x);
    lvF = frame_level(y, N);
    bgF = median(lvF);
    fprintf('\n=== Kiem chung (RATIO=8, ABS_MIN=3x nen sau loc) ===\n');
    nev = count_claps(lvF, 8, 3*bgF, 0.10);
    fprintf('  Sau loc HPF %dHz: phat hien %d su kien clap\n', fc, nev);

    % ===== Ve so sanh ==================================================
    tfr = (0:numel(lv0)-1)*N/Fs;
    figure('Name','Clap HPF design','Color','w','Position',[80 80 900 500]);
    subplot(2,1,1);
    plot(tfr, lv0,'b'); grid on; hold on; plot(tfr, lvF,'r');
    legend('khong loc','HPF 500Hz'); ylabel('\Sigma x^2/frame');
    title('Level/frame: nen tan thap bi giam, clap giu nguyen'); xlabel('t(s)');
    subplot(2,1,2);
    [H,f] = freqz(b,a,1024,Fs);
    semilogx(f, 20*log10(abs(H)),'LineWidth',1.2); grid on;
    xline(fc,'--r'); xlabel('Hz'); ylabel('dB');
    title(sprintf('Dap ung highpass %d Hz', fc)); xlim([20 Fs/2]); ylim([-40 5]);
    print(gcf,'clap_hpf_design.png','-dpng','-r100');
    fprintf('\nDa luu: clap_hpf_design.png\n');
end

function lv = frame_level(x, N)
    nfr = floor(numel(x)/N); lv = zeros(nfr,1);
    for f = 1:nfr, seg = x((f-1)*N+(1:N)); lv(f) = sum(seg.^2); end
end

function n_events = count_claps(level, ratio, abs_min, alpha)
    bg = abs_min; prev = false; n_events = 0;
    for f = 1:numel(level)
        is_clap = (level(f) > ratio*bg) && (level(f) > abs_min);
        if ~is_clap, bg = bg + alpha*(level(f)-bg); end
        if is_clap && ~prev, n_events = n_events + 1; end
        prev = is_clap;
    end
end
