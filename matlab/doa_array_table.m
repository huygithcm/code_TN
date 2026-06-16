%% doa_array_table.m
% Hai tinh nang:
%   1) Ve hinh hoc mang mic (UCA 8 mic, cap doi dien)
%   2) In bang delay TDOA (16 huong x 4 cap) cho thuat toan table-matching
%
% Chay:  doa_array_table

function doa_array_table

    % ----- Tham so -----------------------------------------------------
    R    = 0.040;     % ban kinh UCA (m) -> duong kinh 80 mm
    Fs   = 16000;     % tan so lay mau (Hz)
    C    = 343.0;     % van toc am (m/s)
    N_AZ = 16;        % so huong co dinh (16 -> 22.5 deg)

    % Goc tung kenh (channel-major), cap doi dien: (ch0,ch1)(ch2,ch3)...
    ch_ang = [0, 180, 45, 225, 90, 270, 135, 315];   % do
    mic_x  = R * cosd(ch_ang) * 1e3;                 % mm
    mic_y  = R * sind(ch_ang) * 1e3;

    % =====================================================================
    % 1) VE HINH HOC MANG MIC
    % =====================================================================
    figure('Name','Mic array geometry','Color','w');
    hold on; axis equal; grid on;

    % vong tron mang
    th = linspace(0, 2*pi, 200);
    plot(R*1e3*cos(th), R*1e3*sin(th), 'Color',[0.7 0.7 0.7], 'LineWidth',1);

    % 4 cap doi dien - moi cap mot mau
    pair_col = lines(4);
    for p = 0:3
        iL = 2*p + 1;  iR = 2*p + 2;   % index MATLAB (ch2p, ch2p+1)
        plot([mic_x(iL) mic_x(iR)], [mic_y(iL) mic_y(iR)], ...
             '-', 'Color', pair_col(p+1,:), 'LineWidth', 1.5);
    end

    % cac mic + nhan
    plot(mic_x, mic_y, 'ko', 'MarkerFaceColor','k', 'MarkerSize',8);
    plot(0, 0, 'k+', 'MarkerSize',12, 'LineWidth',1.5);   % tam mang
    for i = 1:8
        txt = sprintf('  ch%d (%g°)', i-1, ch_ang(i));
        text(mic_x(i), mic_y(i), txt, 'FontSize',9, 'FontWeight','bold');
    end

    % truc azimuth
    quiver(0, 0, R*1e3*1.25, 0, 0, 'Color',[0.2 0.2 0.2], ...
           'MaxHeadSize',0.3, 'LineWidth',1);
    text(R*1e3*1.28, 0, 'az=0°', 'FontSize',9);

    lim = R*1e3*1.5;
    xlim([-lim lim]); ylim([-lim lim]);
    xlabel('x (mm)'); ylabel('y (mm)');
    title(sprintf('UCA %d mic — duong kinh %g mm (4 cap doi dien)', 8, 2*R*1e3));

    % =====================================================================
    % 2) IN BANG DELAY TDOA
    % =====================================================================
    phi   = (0:3) * 45;                  % goc baseline tung cap (deg)
    angles = (0:N_AZ-1) * (360/N_AZ);    % huong ung vien (deg)
    scale = (Fs/C) * 2*R;                % (Fs/C)*2R, tre cuc dai (mau)

    table = zeros(N_AZ, 4);
    for a = 1:N_AZ
        for k = 1:4
            table(a,k) = scale * cosd(angles(a) - phi(k));
        end
    end

    fprintf('\n=== Bang delay TDOA ===\n');
    fprintf('R=%.0fmm (D=%.0fmm), Fs=%dHz, C=%.0fm/s, %d huong (buoc %.1f°)\n', ...
            R*1e3, 2*R*1e3, Fs, C, N_AZ, 360/N_AZ);
    fprintf('(Fs/C)*2R = %.6f mau\n\n', scale);
    fprintf('  az(°) | cap0(0°)  cap1(45°)  cap2(90°)  cap3(135°)\n');
    fprintf('  ------+----------------------------------------------\n');
    for a = 1:N_AZ
        fprintf('  %5.1f | %8.4f  %8.4f  %8.4f  %8.4f\n', ...
                angles(a), table(a,1), table(a,2), table(a,3), table(a,4));
    end
    fprintf('\n');
end
