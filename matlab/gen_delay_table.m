%% gen_delay_table.m — sinh bảng trễ TDOA cho DOA (cặp mic đối diện)
%
% Tính bảng trễ kỳ vọng (đơn vị: mẫu) cho từng hướng nguồn cố định, dùng cho
% thuật toán table-matching trong firmware STM32 (g_doa_table[][]).
%
% Mô hình:
%   - Mảng tròn đều (UCA) bán kính R, 8 mic, 4 cặp đối diện qua tâm.
%   - Cặp k = (ch[2k], ch[2k+1]); baseline của cặp k nằm ở góc phi_k = k*45 deg.
%   - Trễ kỳ vọng của cặp k cho nguồn ở azimuth az:
%         lag_k(az) = (Fs/C) * 2R * cos(az - phi_k)   [mẫu]
%     Dấu khớp quy ước GCC_PHAT(ch_chẵn, ch_lẻ) trong firmware.
%
% Chạy:  gen_delay_table            % dùng tham số mặc định (80mm, 16 hướng)
%        gen_delay_table(0.026,16)  % R=26mm, 16 hướng (đường kính 52mm)
%
% In ra: bảng C (dán vào main.c) + bảng MATLAB + lưu CSV.

function gen_delay_table(R, N_AZ)

    if nargin < 1 || isempty(R),    R    = 0.04;  end   % bán kính UCA (m) -> 80mm
    if nargin < 2 || isempty(N_AZ), N_AZ = 16;     end   % số hướng (16 -> 22.5 deg)

    Fs = 16000;       % tần số lấy mẫu (Hz)
    C  = 343.0;       % vận tốc âm (m/s)
    N_PAIRS = 4;      % 4 cặp đối diện

    az_step = 360 / N_AZ; % tính chia ra độ phân giải của từng góc
    angles  = (0:N_AZ-1) * az_step;          % hướng ứng viên (deg)
    phi     = (0:N_PAIRS-1) * 45;            % góc baseline từng cặp (deg)
    scale   = (Fs / C) * 2 * R;              % (Fs/C)*2R, trễ cực đại (mẫu)

    % --- Tính bảng (N_AZ x N_PAIRS) --------------------------------------
    table = zeros(N_AZ, N_PAIRS);
    for a = 1:N_AZ
        for k = 1:N_PAIRS
            table(a,k) = scale * cosd(angles(a) - phi(k));
        end
    end

    % --- Thông tin cấu hình ----------------------------------------------
    fprintf('=== Bang tre TDOA ===\n');
    fprintf('  R = %.0f mm (duong kinh %.0f mm), Fs = %d Hz, C = %.0f m/s\n', ...
            R*1e3, 2*R*1e3, Fs, C);
    fprintf('  So huong = %d (buoc %.1f deg), so cap = %d\n', N_AZ, az_step, N_PAIRS);
    fprintf('  (Fs/C)*2R = %.6f mau (tre cuc dai)\n\n', scale);

    % --- In dạng C (dán vào g_doa_table trong main.c) --------------------
    fprintf('// g_doa_table[%d][%d] - dan vao Src/main.c\n', N_AZ, N_PAIRS);
    fprintf('static const float g_doa_table[DOA_N_AZ][DOA_NPAIRS] = {\n');
    for a = 1:N_AZ
        fprintf('  { %s },  /* az=%5.1f */\n', ...
                strjoin(arrayfun(@(v) sprintf('%10.6ff', v), table(a,:), 'uni', 0), ', '), ...
                angles(a));
    end
    fprintf('};\n\n');

    % --- In dạng MATLAB ---------------------------------------------------
    fprintf('%% doa_table (%dx%d) - dinh dang MATLAB\n', N_AZ, N_PAIRS);
    fprintf('doa_table = [ ...\n');
    for a = 1:N_AZ
        term = ';'; if a == N_AZ, term = ' ];'; end
        fprintf('  %s%s  %% az=%5.1f\n', ...
                strjoin(arrayfun(@(v) sprintf('%10.6f', v), table(a,:), 'uni', 0), '  '), ...
                term, angles(a));
    end
    fprintf('\n');

    % --- Lưu CSV ----------------------------------------------------------
    fname = sprintf('delay_table_%dk_%dmm_%ddir.csv', round(Fs/1000), round(2*R*1e3), N_AZ);
    writematrix(table, fname);
    fprintf('Da luu: %s\n', fname);
end
