%% test_srp_sim.m - one-shot headless check of the SRP-PHAT core.
% Synthesizes the same 2-source scene as srp_beamform_multi("sim")
% (az 60 deg chirp + az 250 deg noise) and verifies the two strongest
% SRP-PHAT peaks land near the true azimuths.

FS = 16000; NCH = 8; NSAMP = 1024; C = 343.0; R = 0.040;
ang_deg = [0 180 45 225 90 270 135 315];
micPos  = R * [cosd(ang_deg); sind(ang_deg)]';

% ---- synthesize 2 sources (same as sim_frame) ----------------------------
rng(7);
t  = (0:NSAMP-1)'/FS;
f0 = 500; f1 = 1500;
s1 = sin(2*pi*(f0*t + (f1-f0)/(2*t(end))*t.^2));
s1 = s1 .* (0.5*(1 - cos(2*pi*(0:NSAMP-1)'/NSAMP)));
s2 = randn(NSAMP,1) * 0.7;
azTrue = [60 250];
x = zeros(NSAMP, NCH);
for m = 1:NCH
    d1 = -(micPos(m,:) * [cosd(azTrue(1)); sind(azTrue(1))]) / C;
    d2 = -(micPos(m,:) * [cosd(azTrue(2)); sind(azTrue(2))]) / C;
    x(:,m) = frac_delay(s1, d1*FS) + frac_delay(s2, d2*FS) + 0.05*randn(NSAMP,1);
end

% ---- SRP-PHAT core (same math as srp_beamform_multi) ----------------------
azGrid = 0:2:358; elGrid = 0:10:60;
[AZ, EL] = meshgrid(azGrid, elGrid);
ux = cosd(EL).*cosd(AZ); uy = cosd(EL).*sind(AZ);
tau = zeros(NCH, numel(AZ));
for m = 1:NCH
    tau(m,:) = -(micPos(m,1)*ux(:) + micPos(m,2)*uy(:))' / C;
end
fBins = (0:NSAMP/2)' * FS/NSAMP;
useBin = fBins >= 300 & fBins <= 4000;
fUse = fBins(useBin);
expArg = 2i*pi*fUse;   % +j: undo the propagation delay e^{-j2pi f tau}

win = 0.5*(1 - cos(2*pi*(0:NSAMP-1)'/NSAMP));
X = fft((x - mean(x,1)) .* win, NSAMP);
X = X(useBin,:);
X = X ./ max(abs(X), 1e-12);

% ---- successive cancellation: find peak, null it per bin, re-scan ---------
fprintf("True sources: az = %d, %d deg\n", azTrue(1), azTrue(2));
ok = true;
found = zeros(2,2);    % [az el] per source
for s = 1:2
    Y = zeros(numel(fUse), size(tau,2));
    for m = 1:NCH
        Y = Y + X(:,m) .* exp(expArg * tau(m,:));
    end
    P = sum(abs(Y).^2, 1);
    Pmap = reshape(P, size(AZ));
    [azProf, elIdx] = max(Pmap, [], 1);
    [~, i] = max(azProf);
    found(s,:) = [azGrid(i), elGrid(elIdx(i))];

    % project out the found source: X <- X - a (a^H X)/M  per frequency bin
    gIdx = sub2ind(size(AZ), elIdx(i), i);
    a = exp(-expArg * tau(:, gIdx)');         % [nBins x NCH] propagation phases
    proj = sum(conj(a) .* X, 2) / NCH;        % a^H X / M  per bin
    X = X - a .* proj;
end

for s = 1:2
    err = min(abs(found(s,1) - azTrue), 360 - abs(found(s,1) - azTrue));
    fprintf("Peak %d: az=%5.1f el=%4.1f  (err to nearest true az: %.1f deg)\n", ...
            s, found(s,1), found(s,2), min(err));
    if min(err) > 10, ok = false; end
end
if ok, fprintf("PASS: both peaks within 10 deg of true azimuths\n");
else,  fprintf("FAIL: peak(s) off by more than 10 deg\n"); end

function y = frac_delay(s, dSamp)
N = numel(s);
S = fft(s);
k = [0:N/2, -N/2+1:-1]';
y = real(ifft(S .* exp(-2i*pi*k*dSamp/N)));
end
