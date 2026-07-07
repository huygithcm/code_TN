%% test_doa_algorithm.m
% Mo phong + kiem chung thuat toan DOA truoc khi flash firmware.
% Mirror dung logic firmware (nhanh simplify/doa-code):
%   - GCC-PHAT giua 4 cap mic doi dien + noi suy parabol
%   - Khop bang delay 16x4 (table matching, min-SSE) -> huong roi rac
%   - Cong clap: chi nhan frame co muc vot len tren nen nhieu
%   - Cua so 1 giay: bau chon huong -> nguon clap manh nhat
%
% Chay headless:  test_doa_algorithm

function test_doa_algorithm

    % ===== Tham so (khop firmware) =====================================
    Fs   = 16000; N = 1024; C = 343.0; R = 0.040;
    N_AZ = 16; AZ_STEP = 360/N_AZ;          % 16 huong, 22.5 deg
    WIN_BLOCKS = 16;                        % ~1 s
    RESID_MAX  = 0.5;
    CLAP_RATIO = 6.0; CLAP_BG_ALPHA = 0.10;
    ch_ang  = [0 180 45 225 90 270 135 315];
    mic_pos = R*[cosd(ch_ang(:)) sind(ch_ang(:))];   % (8x2)

    % Bang delay 16x4 (= g_doa_table firmware)
    DOA_ANGLES = (0:N_AZ-1)*AZ_STEP;
    phi = (0:3)*45;  scale = (Fs/C)*2*R;
    doa_table = scale * cosd(DOA_ANGLES(:) - phi);   % (16x4)

    % ===== Kich ban mo phong ==========================================
    % Nen nhieu khap noi + cac tieng vo tay tu cac huong da biet (giay nao).
    T_sec  = 5;                  % tong thoi gian
    noise_amp = 0.01;            % bien do nhieu nen (incoherent)
    % clap: {giay, azimuth that}
    claps = { 1, 45 ; 2, 135 ; 3, 270 ; 4, 0 };   % giay 5 = im lang (no clap)
    rng(7);                      % co dinh seed de tai lap

    L = T_sec*Fs;  t = (0:L-1)/Fs;
    sig = noise_amp*randn(8, L);                 % nen nhieu doc lap moi mic

    for cc = 1:size(claps,1)
        t0 = claps{cc,1} - 0.5;                  % clap o giua giay do
        az = claps{cc,2};
        src = clap_burst(t, t0);                 % xung bang rong
        u = [cosd(az); sind(az)];
        for i = 1:8
            d_i = -(mic_pos(i,:)*u)/C;            % tre toi mic i (s)
            sig(i,:) = sig(i,:) + interp1(t, src, t - d_i, 'linear', 0);
        end
    end

    % ===== Vong xu ly tung frame (mirror DOA_Task) ====================
    nfr = floor(L/N);
    CLAP_ABS_MIN = 5*noise_amp^2*N;     % nguong tuyet doi ~5x muc nen
    bg = CLAP_ABS_MIN; win_start = 0;
    vote = zeros(1,N_AZ); n_acc = 0;
    sec = 0; n_fail = 0;

    fprintf('=== Mo phong DOA (clap detector) ===\n');
    fprintf('Fs=%d N=%d, %d huong/%.1f deg, clap ratio=%g\n\n', ...
            Fs, N, N_AZ, AZ_STEP, CLAP_RATIO);

    for f = 1:nfr
        X = sig(:, (f-1)*N + (1:N));

        % 4 tre cap doi dien
        lags = zeros(4,1);
        for k = 1:4
            lags(k) = gcc_phat(X(2*k-1,:), X(2*k,:), N);
        end
        % khop bang -> huong + residual
        [az, resid, idx] = table_match(lags, doa_table, DOA_ANGLES, R, Fs, C);

        % cong clap
        level = sum(X(1,:).^2);
        is_clap = (level > CLAP_RATIO*bg) && (level > CLAP_ABS_MIN);
        if ~is_clap
            bg = bg + CLAP_BG_ALPHA*(level - bg);
        end
        if is_clap && resid < RESID_MAX
            vote(idx) = vote(idx) + (1 - resid);
            n_acc = n_acc + 1;
        end

        % cua so 1 giay
        if (f - win_start) >= WIN_BLOCKS
            win_start = f; sec = sec + 1;
            if n_acc > 0
                [~, best] = max(vote);
                az_out = DOA_ANGLES(best);
                % kiem tra so voi clap that cua giay nay
                exp_az = NaN;
                for cc = 1:size(claps,1)
                    if claps{cc,1} == sec, exp_az = claps{cc,2}; end
                end
                ok = ~isnan(exp_az) && (az_out == exp_az);
                if isnan(exp_az), ok = false; end   % co clap nhung khong nen co
                if ~ok, n_fail = n_fail + 1; end
                fprintf('  giay %d: cam target az=%3d°  (%d clap frames)  [that: %s]  %s\n', ...
                        sec, az_out, n_acc, num2str(exp_az), tern(ok));
            else
                exp_silence = true;
                for cc = 1:size(claps,1)
                    if claps{cc,1} == sec, exp_silence = false; end
                end
                if ~exp_silence, n_fail = n_fail + 1; end
                fprintf('  giay %d: no clap%s\n', sec, ...
                        tern_msg(exp_silence, '  [OK: dung la im lang]', '  [FAIL: bo sot clap]'));
            end
            vote(:) = 0; n_acc = 0;
        end
    end

    fprintf('\n');
    if n_fail == 0
        fprintf('==> TAT CA PASS: thuat toan san sang flash.\n');
    else
        fprintf('==> %d giay SAI: can xem lai truoc khi flash.\n', n_fail);
    end
end

% ----- xung clap bang rong (decaying noise burst) ----------------------
function s = clap_burst(t, t0)
    tau = 0.02;                 % hang so suy giam 20 ms
    env = exp(-(t - t0)/tau) .* (t >= t0);
    s = 1.0 * env .* randn(size(t));   % bien do ~1 >> nen 0.01
end

% ----- GCC-PHAT + noi suy parabol --------------------------------------
% Quy uoc dau khop firmware GCC_PHAT(a,b): tra +D khi b tre hon a mot luong D.
% ifft(X.*conj(Y)) cho dau nguoc (-D), nen dao dau lag cuoi cung.
function lag = gcc_phat(x, y, N)
    X = fft(x, N); Y = fft(y, N);
    G = X .* conj(Y);
    G = G ./ max(abs(G), 1e-10);
    r = fftshift(real(ifft(G)));
    [~, i] = max(r);
    lag = i - N/2 - 1;
    if i > 1 && i < N
        ym1 = r(i-1); y0 = r(i); yp1 = r(i+1);
        den = 2*(2*y0 - ym1 - yp1);
        if abs(den) > 1e-10, lag = lag + (yp1 - ym1)/den; end
    end
    lag = -lag;                 % khop quy uoc dau cua firmware
end

% ----- khop bang (mirror DOA_Compute) ----------------------------------
function [az, resid, idx] = table_match(lags, table, angles, R, Fs, C)
    e = sum((lags(:).' - table).^2, 2);   % (16x1) SSE moi huong
    [emin, idx] = min(e);
    az = angles(idx);
    max_lag = Fs*2*R/C;
    resid = emin / (4*max_lag^2 + 1e-10);
end

function s = tern(ok),  if ok, s='OK'; else, s='FAIL'; end, end
function s = tern_msg(c,a,b), if c, s=a; else, s=b; end, end
