function srp_beamform_multi(port, nSources, maxFrames)
%SRP_BEAMFORM_MULTI  Wideband SRP-PHAT beamforming for multiple sound sources.
%
%   srp_beamform_multi()             - auto port "COM12", up to 3 sources
%   srp_beamform_multi("COM12", 2)   - explicit port, up to 2 sources
%   srp_beamform_multi("sim")        - simulation: 2 synthetic sources, no HW
%
%   Reads RAW1 frames (8 ch x 1024 samples, int32 LE, channel-major) from the
%   STM32 OTG CDC port and computes a steered response power (SRP) map with
%   PHAT weighting over an azimuth x elevation grid. Multiple sources show up
%   as multiple peaks; the strongest nSources peaks (with angular separation
%   enforced) are reported and plotted live.
%
%   Array geometry MUST match mic_pos[] in Src/main.c:
%   UCA radius 40 mm, ch = pair*2+side, pairs wire diametrically opposed mics.

if nargin < 1, port = "COM12"; end
if nargin < 2, nSources = 3;   end
if nargin < 3, maxFrames = inf; end   % stop after N frames (for testing)

% ---- constants matching the firmware ------------------------------------
FS    = 16000;            % sample rate [Hz]
NCH   = 8;                % channels
NSAMP = 1024;             % samples per channel per frame
HDR   = 12;               % RAW1 header bytes
FRAME = HDR + NCH*NSAMP*4;
C     = 343.0;            % speed of sound [m/s]
R     = 0.040;            % UCA radius [m]

% mic_pos: identical to Src/main.c (pair p -> L at p*45 deg, R at +180 deg)
ang_deg = [0 180 45 225 90 270 135 315];
micPos  = R * [cosd(ang_deg); sind(ang_deg)]';      % [8 x 2] metres

% ---- steering grid -------------------------------------------------------
azGrid = 0:2:358;                  % azimuth [deg]
elGrid = 0:10:60;                  % elevation [deg]
[AZ, EL] = meshgrid(azGrid, elGrid);
% far-field unit vectors projected on the array plane (z drops out: planar array)
ux = cosd(EL).*cosd(AZ);   uy = cosd(EL).*sind(AZ);
% per-mic expected delay [s] for each grid point: tau_m = -(pos_m . u)/C
tau = zeros(NCH, numel(AZ));
for m = 1:NCH
    tau(m,:) = -(micPos(m,1)*ux(:) + micPos(m,2)*uy(:))' / C;
end

% ---- FFT bins used (speech band; skip DC and near-Nyquist) ---------------
NFFT  = NSAMP;
fBins = (0:NFFT/2)' * FS/NFFT;
useBin = fBins >= 300 & fBins <= 4000;
fUse  = fBins(useBin);
% steering matrix W [nBins x nGrid x ... ] built per mic on the fly (memory-light)
expArg = 2i*pi*fUse;   % +j: undo the propagation delay e^{-j2pi f tau}   [nBins x 1]

PEAK_REL = 0.25;         % residual peak must reach 25% of the first peak's power

% ---- source: serial or simulation ---------------------------------------
simMode = strcmpi(string(port), "sim");
if ~simMode
    clear sp;
    sp = serialport(port, 115200, "Timeout", 5);
    flush(sp);
    fprintf("Listening on %s ...\n", port);
end

fig = figure("Name","Radar huong nguon am (SRP-PHAT)","NumberTitle","off", ...
             "Position",[200 100 700 700], "Color","w");
ax = axes(fig); hold(ax,"on"); axis(ax,"equal"); axis(ax,"off");
srcColor = [0.85 0.1 0.1; 0.0 0.45 0.85; 0.1 0.6 0.2];   % S1 red, S2 blue, S3 green

buf = uint8([]);
nDone = 0;
while ishandle(fig) && nDone < maxFrames
    % ---- acquire one frame ----------------------------------------------
    if simMode
        x = sim_frame(micPos, FS, NSAMP, C);  pause(0.2);
    else
        [x, buf] = read_frame(sp, buf, FRAME, HDR, NCH, NSAMP);
        if isempty(x), continue; end
    end

    % ---- PHAT-whitened spectra ------------------------------------------
    win = 0.5*(1 - cos(2*pi*(0:NSAMP-1)'/NSAMP));   % Hann (no toolbox needed)
    X = fft(x .* win, NFFT);                   % [NFFT x NCH]
    X = X(useBin, :);                          % keep speech band
    X = X ./ max(abs(X), 1e-12);               % PHAT: unit magnitude

    % ---- successive cancellation: scan, take peak, null it, re-scan ------
    % With an 80 mm aperture the main lobe is very wide, so a strong source
    % buries weaker ones under its sidelobes; projecting the found source out
    % of the whitened spectra per bin (X <- X - a a^H X / M) before the next
    % scan recovers them.
    Xw = X;
    found = zeros(0, 2);                       % [az el] per detected source
    P1 = 0;
    for s = 1:nSources
        Y = zeros(numel(fUse), size(tau,2));
        for m = 1:NCH
            Y = Y + Xw(:,m) .* exp(expArg * tau(m,:));
        end
        P = sum(abs(Y).^2, 1);
        Pmap_s = reshape(P, size(AZ));
        [azProf, elIdx] = max(Pmap_s, [], 1);
        [v, i] = max(azProf);
        if s == 1
            Pmap = Pmap_s;  azProf1 = azProf;  P1 = v;   % keep for display
        elseif v < PEAK_REL * P1
            break;                              % residual too weak: stop
        end
        fprintf("S%d: az=%d el=%d  power=%.2f (x P1)\n", s, azGrid(i), elGrid(elIdx(i)), v/P1);
        found(end+1,:) = [azGrid(i), elGrid(elIdx(i))]; %#ok<AGROW>

        gIdx = sub2ind(size(AZ), elIdx(i), i);
        a = exp(-expArg * tau(:, gIdx)');       % [nBins x NCH] propagation phases
        Xw = Xw - a .* (sum(conj(a) .* Xw, 2) / NCH);
    end

    % ---- radar view -------------------------------------------------------
    % One top-down picture: mic array at the center, an arrow per detected
    % source pointing where the sound comes from, and a blue outline around
    % the circle that bulges toward directions with more acoustic energy.
    cla(ax);

    % reference circle + cross hairs + degree labels
    thc = linspace(0, 2*pi, 181);
    plot(ax, cos(thc), sin(thc), "-", "Color", [0.75 0.75 0.75]);
    plot(ax, [-1.05 1.05], [0 0], ":", "Color", [0.85 0.85 0.85]);
    plot(ax, [0 0], [-1.05 1.05], ":", "Color", [0.85 0.85 0.85]);
    for d = 0:45:315
        text(ax, 1.16*cosd(d), 1.16*sind(d), sprintf("%d%c", d, 176), ...
             "HorizontalAlignment","center", "Color",[0.45 0.45 0.45], "FontSize",9);
    end

    % energy outline: radius 1 (quiet) .. 1+0.25 (loudest direction)
    pn = azProf1 / max(azProf1);
    rr = 1 + 0.25*[pn pn(1)];
    tt = deg2rad([azGrid azGrid(1)]);
    plot(ax, rr.*cos(tt), rr.*sin(tt), "-", "Color",[0.2 0.5 0.9], "LineWidth",1.2);

    % mic array (to scale exaggerated for visibility)
    scatter(ax, micPos(:,1)/R*0.12, micPos(:,2)/R*0.12, 18, "k", "filled");
    text(ax, 0, -0.05, "mic array", "HorizontalAlignment","center", ...
         "FontSize",8, "Color",[0.3 0.3 0.3]);

    % one arrow per detected source
    legendTxt = strings(0);
    for s = 1:size(found,1)
        a = found(s,1);  e = found(s,2);
        c = srcColor(min(s, size(srcColor,1)), :);
        quiver(ax, 0, 0, 0.92*cosd(a), 0.92*sind(a), 0, "Color",c, ...
               "LineWidth",3, "MaxHeadSize",0.35);
        text(ax, 1.34*cosd(a), 1.34*sind(a), ...
             sprintf("Nguon %d\n%.0f%c (cao %.0f%c)", s, a, 176, e, 176), ...
             "HorizontalAlignment","center", "FontWeight","bold", ...
             "Color",c, "FontSize",11);
        legendTxt(end+1) = sprintf("Nguon %d: huong %.0f%c, goc cao %.0f%c", s, a, 176, e, 176); %#ok<AGROW>
    end
    if isempty(legendTxt), legendTxt = "Chua phat hien nguon am ro"; end

    xlim(ax, [-1.55 1.55]); ylim(ax, [-1.55 1.55]);
    title(ax, ["Nhin tu TREN XUONG - mui ten = huong nguon am"; join(legendTxt, "    ")], ...
          "FontSize", 12);
    drawnow limitrate;
    nDone = nDone + 1;
end
if ~simMode, delete(sp); end
end

% ========================================================================
function [x, buf] = read_frame(sp, buf, FRAME, HDR, NCH, NSAMP)
% Append available bytes, sync on double "RAW1" magic, return one frame
% as [NSAMP x NCH] double, and the remaining buffer.
x = [];
n = sp.NumBytesAvailable;
if n > 0, buf = [buf; read(sp, n, "uint8")']; end
if numel(buf) < 2*FRAME + 4, return; end
magic = uint8('RAW1');
pos = 0;
for i = 1:(numel(buf) - FRAME - 4)
    if isequal(buf(i:i+3)', magic) && isequal(buf(i+FRAME:i+FRAME+3)', magic)
        pos = i; break;
    end
end
if pos == 0, buf = buf(end-FRAME:end); return; end
payload = buf(pos+HDR : pos+FRAME-1);
v = double(typecast(payload(:), 'int32'));         % NCH*NSAMP, channel-major
x = reshape(v, NSAMP, NCH);                        % [NSAMP x NCH]
x = x - mean(x, 1);                                % remove DC per channel
buf = buf(pos+FRAME:end);
end

% ========================================================================
function x = sim_frame(micPos, FS, NSAMP, C)
% Two synthetic far-field sources (az 60 and 250 deg) + noise, for testing.
t  = (0:NSAMP-1)'/FS;
f0 = 500; f1 = 1500;                       % linear chirp, no toolbox needed
s1 = sin(2*pi*(f0*t + (f1-f0)/(2*t(end))*t.^2));
s1 = s1 .* (0.5*(1 - cos(2*pi*(0:NSAMP-1)'/NSAMP)));
s2 = randn(NSAMP,1) * 0.7;
x  = zeros(NSAMP, size(micPos,1));
for m = 1:size(micPos,1)
    d1 = -(micPos(m,:) * [cosd(60);  sind(60)])  / C;
    d2 = -(micPos(m,:) * [cosd(250); sind(250)]) / C;
    x(:,m) = frac_delay(s1, d1*FS) + frac_delay(s2, d2*FS) + 0.05*randn(NSAMP,1);
end
x = x * 8000;
end

function y = frac_delay(s, dSamp)
N = numel(s);
S = fft(s);
k = [0:N/2, -N/2+1:-1]';
y = real(ifft(S .* exp(-2i*pi*k*dSamp/N)));
end
