%% test_srp_check.m — quick headless check of the SRP delay-and-sum DOA
% Simulates a 1 kHz plane wave from each of the 8 fixed directions plus a
% pure-noise frame, and verifies doa_srp (same table + logic as the live
% script / STM32 firmware) recovers the right discrete angle.

Fs = 16000; N = 1024; C = 343.0; R = 0.040; F0 = 1000;
ANG = [0, 180, 45, 225, 90, 270, 135, 315];          % channel angles
mic_pos = R * [cosd(ANG(:)), sind(ANG(:))];          % (8x2)

% Hardcoded table (same as stm32_mic_array_live.m)
DOA_ANGLES = 0:45:315;
doa_table = [ ...
  -3.731778  -0.546506  -3.185272  -1.865889  -1.865889  -3.185272  -0.546506 ;
  -2.638766   0.546506  -3.185272   0.000000  -2.638766  -1.319383  -1.319383 ;
   0.000000   1.319383  -1.319383   1.865889  -1.865889   1.319383  -1.319383 ;
   2.638766   1.319383   1.319383   2.638766   0.000000   3.185272  -0.546506 ;
   3.731778   0.546506   3.185272   1.865889   1.865889   3.185272   0.546506 ;
   2.638766  -0.546506   3.185272   0.000000   2.638766   1.319383   1.319383 ;
   0.000000  -1.319383   1.319383  -1.865889   1.865889  -1.319383   1.319383 ;
  -2.638766  -1.319383  -1.319383  -2.638766   0.000000  -3.185272   0.546506 ];

t = (0:N-1)/Fs;
n_fail = 0;
fprintf('=== SRP check: source at each of the 8 fixed directions ===\n');
for az_true = DOA_ANGLES
    u = [cosd(az_true); sind(az_true)];
    sig = zeros(8, N);
    for i = 1:8
        d_i = -(mic_pos(i,:) * u) / C;               % arrival delay (s)
        sig(i,:) = sin(2*pi*F0*(t - d_i)) + 0.05*randn(1,N);
    end
    [az_est, ~, cs] = doa_srp(sig, doa_table, DOA_ANGLES);
    ok = az_est == az_true;
    if ~ok, n_fail = n_fail + 1; end
    fprintf('  true %3d  ->  est %3d   contrast %.2f   %s\n', ...
            az_true, az_est, cs, ternary(ok));
end

fprintf('=== Noise-only frame (no source) ===\n');
[az_n, ~, cs_n] = doa_srp(randn(8, N)*0.1, doa_table, DOA_ANGLES);
fprintf('  est %3d   contrast %.2f   %s\n', az_n, cs_n, ...
        ternary(cs_n < 1.2));
if cs_n >= 1.2, n_fail = n_fail + 1; end

if n_fail == 0
    fprintf('\nALL PASS\n');
else
    fprintf('\n%d FAIL\n', n_fail);
end

function s = ternary(ok)
    if ok, s = 'OK'; else, s = 'FAIL'; end
end

function [az, el, contrast] = doa_srp(data_f, doa_table, angles_deg)
% Copy of the live-script doa_srp (mirror STM32 DOA_SRP).
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
    el = 0;
end
