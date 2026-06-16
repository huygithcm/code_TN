%% doa_live_plot.m
% Live polar plot of the DOA fixes printed by the firmware on the ST-Link
% VCP (COM3, 115200 8N1). The firmware prints ~1 fix/s:
%   DOA seq=832 az=315.0 cs=2.4
% Azimuth is discrete (one of 8 fixed 45-deg directions, SRP delay-and-sum);
% cs = SRP contrast (peak/mean beam power, >=1) shown as needle length and
% in the title. A fading trail shows the recent history.
%
% Stop with Ctrl+C or by closing the figure window.

PORT     = "COM3" + ...
    "";
BAUD     = 115200;
TRAIL_N  = 20;          % number of past fixes kept in the trail

% --- serial port ---------------------------------------------------------
clear sp;                       % release a stale handle from a previous run
sp = serialport(PORT, BAUD, "Timeout", 5);
configureTerminator(sp, "CR/LF");
flush(sp);
fprintf("Listening on %s ... (Ctrl+C to stop)\n", PORT);

% --- figure --------------------------------------------------------------
fig = figure("Name", "STM32 DOA live", "NumberTitle", "off");
pax = polaraxes(fig);
pax.ThetaZeroLocation = "right";   % 0 deg = +X axis of the array
pax.ThetaDir = "counterclockwise";
pax.RLim = [0 1];
pax.RTick = [0 0.25 0.5 0.75 1];
pax.RTickLabel = ["1", "1.75", "2.5", "3.25", ">=4"];   % contrast rings
hold(pax, "on");
trail  = polarscatter(pax, nan(1, TRAIL_N), nan(1, TRAIL_N), 25, "filled", ...
                      "MarkerFaceColor", [0.3 0.6 1.0], "MarkerFaceAlpha", 0.35);
needle = polarplot(pax, [0 0], [0 0], "r-", "LineWidth", 2.5);
marker = polarscatter(pax, 0, 0, 90, "r", "filled");
title(pax, "Waiting for DOA fix ...");

az_hist = nan(1, TRAIL_N);
r_hist  = nan(1, TRAIL_N);

% --- read loop -----------------------------------------------------------
while ishandle(fig)
    line = readline(sp);
    if isempty(line); continue; end
    v = sscanf(line, "DOA seq=%lu az=%f cs=%f");
    if numel(v) ~= 3; continue; end     % skip [MON]/[USB]/[STK] lines

    seq = v(1); az = v(2); cs = v(3);
    th = deg2rad(az);
    r  = min(max((cs - 1) / 3, 0), 1);  % contrast 1 -> center, >=4 -> rim

    % update trail (newest last)
    az_hist = [az_hist(2:end), th];
    r_hist  = [r_hist(2:end),  r];
    set(trail,  "ThetaData", az_hist, "RData", r_hist);
    set(needle, "ThetaData", [th th], "RData", [0 r]);
    set(marker, "ThetaData", th, "RData", r);
    title(pax, sprintf("seq=%lu   az = %.0f%c   contrast = %.1f", ...
                       seq, az, char(176), cs));
    drawnow limitrate;
end

delete(sp);
fprintf("Stopped.\n");
