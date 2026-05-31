function check_mic_angle_realtime(port)
%CHECK_MIC_ANGLE_REALTIME Continuously print mic0/mic1 TDOA angle.
%
%   check_mic_angle_realtime("COM12")
%
% Use the OTG USB CDC COM port, not the ST-LINK VCP status port.
% Stop with Ctrl+C.

    if nargin < 1 || isempty(port)
        port = "COM12";
    end

    fprintf('Starting realtime angle check on %s...\n', string(port));
    fprintf('Use a sharp click/tap or a steady tone near the mic pair.\n');
    fprintf('Stop with Ctrl+C.\n\n');

    read_mic_raw(port, inf);
end
