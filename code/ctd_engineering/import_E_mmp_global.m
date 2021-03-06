function [eng] = import_E_mmp_global(filename)
%=========================================================================
% DESCRIPTION
%   Imports engineering and auxiliary sensor data into a matlab data structure
%   from an ascii 'E' file unpacked from a binary file acquired from an OOI
%   McLane Profiler deployed on a 'global' (as opposed to 'coastal') mooring. 
%
% USAGE:  eng = import_E_mmp_global(filename)
%
%   INPUT
%     filename = an ASCII text 'E' file created from the profiler raw binary
%                data by using the McLane unpacker software v3.10 pr v3.12. 
%                the internal structure of the file can be any one of 4
%                possible formats, set by the 2 binary unpacker switches.
%
%                See Notes.
%
%   OUTPUT
%     eng = a scalar data structure. for structure fieldnames and documentation
%           go to the initialization section in this code. fields containing
%           sensor data will be column vectors. this routine is meant to be 
%           called once for each profile in a deployment so that the imported
%           data will be contained in an array of structures, with the index of
%           each element of the structure denoting the profile number. profile
%           number 0 is not processed.
%
% DEPENDENCIES
%   Matlab R2018b
%
% NOTES
%   OOI 'Global' engineering sensor suite:
%      pressure (from CTD on profiler)
%      oxygen (Aanderaa optode 4330) 
%      ECO doublet (WETLabs FLBBRTD): chl flr, 700nm backscatter
%
%   For McLane profiler version (5.00) using Unpacker V3.12 there are 2 export
%   choices for unpacking that can result in 'E' files with 4 different 
%   internal structures. The choices are:
%     (a) data delimiters: comma separated or space padded columns
%     (b) whether or not to include: header and on and off date/time text rows.
%   This code will work with any of the 4 formats.
%
% AUTHOR
%   Russ Desiderio, desi@ceoas.oregonstate.edu
%
% REVISION HISTORY
%.. 2020-03-01: desiderio: initial code
%.. 2020-05-04: desiderio: radMMP version 3.00 (OOI coastal and global)
%.. 2021-05-12: desiderio: 
%..             (a) backtrack field initialization changed to empty charvector
%..             (b) added detail to error message checking # of data columns
%..             (c) added profile_date field (must init as nan), therefore (b):
%..             (d) added 1 to values of sensor_field_indices vector
%..             (e) calculates value for profile date field
%.. 2021-05-14: desiderio: radMMP version 3.10 (OOI coastal and global)
%.. 2021-05-24: desiderio: radMMP version 4.0
%=========================================================================

%----------------------
% PRELIMINARY SET-UP
%----------------------
number_of_hardcoded_data_columns = 8;  % exclusive of date-time

%.. initialize structure before checking input to make sure that when
%.. this code is used inside of a for loop to process all the profiles
%.. of a deployment, all of the elements of the structure array (one
%.. for each profile) have the same set of field names, including those
%.. with no data, to avoid dissimilar structure assignment exceptions.

%.. A structure's fields can be accessed by numerically indexing into
%.. the fieldnames. The fieldname indices are determined by the order
%.. of field creation, set as follows.  

eng.deployment_ID = '';
eng.profile_number = []; % scalar
eng.profile_date   = nan; % from eng timestamps even when no real data
eng.profile_direction = '';
eng.data_status = {''};  % 'imported' or 'no data' or 'no datafile'
eng.code_history = {mfilename}; % the name of this program
 
eng.header    = '';    % populated if Unpacker header option is enabled
eng.backtrack = '';    % 'yes' if at least one backtrack episode, else 'no'
eng.time      = [];    % [serial datenumber]
eng.current   = [];    % [mA]
eng.voltage   = [];    % [V]
eng.pressure  = [];    % [dbar]
eng.oxygen    = [];    % [uM] not corrected for salinity and pressure
eng.optode_temperature = [];  % [degC]
eng.chl       = [];    % [counts]
eng.bback     = [];    % [counts]
eng.eco_temperature    = [];  % counts
eng.dpdt      = [];    % [dbar/s]
eng.profile_mask         = [];     % true values denote good data
eng.sensor_field_indices = (9:18); % these fields will be binned on pressure
eng.pressure_bin_values  = [];     % later
eng.binning_parameters   = [];     % later: [pr_min binsize pr_max]
eng.acquisition_rate_Hz_calculated = nan;  % derived scalar

%.. the offset values used in processing are those in the metadata file
eng.fluorometer_depth_offset_m = 0;  % initialized to 0
eng.optode_depth_offset_m      = 0;  % initialized to 0

eng.sensors_on    = '';  % populated if Unpacker header option is enabled
eng.vehicle_begin = '';  % populated if Unpacker header option is enabled
eng.ramp_exit     = '';  % populated if Unpacker header option is enabled
eng.profile_exit  = '';  % populated if Unpacker header option is enabled
eng.vehicle_stop  = '';  % populated if Unpacker header option is enabled
eng.sensors_off   = '';  % populated if Unpacker header option is enabled

%----------------------
% CHECK INPUT ARGUMENTS
%----------------------
%.. sometimes the functions disp and fprintf, and particularly labels
%.. in figures, don't work well with backslashes, so change them to
%.. forward slashes which works fine in windows paths.
filename = strrep(filename, '\', '/');

check_infile = exist(filename, 'file');
if check_infile ~=2
    disp(['WARNING: Could not find file ', filename]);
    eng.data_status = {'no datafile'};
    %.. parse filename for profile number
    [~, name, ~] = fileparts(filename);
    eng.profile_number = str2double(name(end-6:end));
    return
end

%------
% BEGIN
%------

%.. read in entire file as a cell whose lone element is 
%.. a cell array (column vector) of character vectors.
%.. each character vector is a row of ascii text from the input file. 
fid = fopen(filename, 'rt');
C = textscan(fid, '%s', 'whitespace', '', 'delimiter', '\n');
fclose(fid);
C=C{1};
%.. C is now a cell column vector of character vectors.
%.. trim leading and trailing whitespace from all rows. 
C = strtrim(C);
%.. DELETE blank rows
C(cellfun('isempty', C)) = [];
%.. determine whether there are non-data rows.
%..   if so, normal McLane-unpacked 'E' files will have one 'Profile'
%..   row as the first non-blank row of the file. 
%..
%..   there will also be a 'Profile exit' row after the data rows
idx = find(strncmpi(C, 'Profile', 7));
if ~isempty(idx)  % there are rows of text that are not data
    %.. read profile number
    eng.profile_number = sscanf(C{idx(1)}(8:end), '%u');
    C(idx(1)) = [];  % delete profilerow from the data
    %.. the first 3 rows are now
    %.. (1) sensors were turned on text
    %.. (2) vehicle began profiling text
    %.. (3) header (column labels)
    eng.sensors_on = C{1};
    eng.vehicle_begin = C{2};
    eng.header = C{3};
    C(1:3) = [];
    %.. at the end of the file, there are 4 text lines.
    eng.ramp_exit    = C{end-3};
    eng.profile_exit = C{end-2};
    eng.vehicle_stop = C{end-1};
    eng.sensors_off  = C{end};
    C(end-3:end) = [];
else  % no header, footer, no 'Exception Encountered' rows
    %.. because C only contains data lines, 
    %.. try to get profile number from filename.
    [~, name, ~] = fileparts(filename);
    %.. the unpacker can add a prefix, not a suffix, so the last
    %.. 7 characters of the filename should be conserved.
    %.. if this fails, the result will probably be an entry of NaN.
    eng.profile_number = str2double(name(end-6:end));
end

%..  for diagnostics only
% eng = C;
% return

%.. sometimes the profiler seems to get 'stuck', stops profiling,
%..   temporarily reverses direction (backtracks), then resumes profiling.
%..   If the binary files were unpacked with headers enabled then
%..   the data will be interrupted by text lines.
%.. delete all remaining text lines if present  
mask = ~cellfun('isempty', regexp(C, '[a-df-zA-DF-Z]'));
C(mask) = [];

%.. normally at this stage there are only data rows.
%.. convert comma delimited data to space-padded.
%.. if C is already space-padded, nothing changes.
C = strrep(C, ',', ' ');
%.. turn into a character array so that the date and time fields can be
%.. separated from the data fields.
cc = char(C);

%.. trap out if no data at all found
if isempty(cc)
    disp(['WARNING: No data found in ' filename]);
    eng.data_status = {'no data'};
    return
end

%.. copy spaces into delimiter columns in the date time fields;
%.. expected format: MM/DD/YYYY hh:mm:ss
%.. also add a delimiter at the end of each row.
cc(:, [3 6 11 14 17 20 end+1]) = ' ';
%.. figure out the number of columns of data by doing a generalized
%.. read of the first row
[~, ncol] = sscanf(cc(1,:), '%f');
%.. check
if ncol~=number_of_hardcoded_data_columns + 6
    xpctd = num2str(number_of_hardcoded_data_columns);
    found = num2str(ncol-6);
    msg = ['The function ' mfilename ' expects files with ' xpctd ' data ' ...
           'columns, excluding date and time fields; ' found ' were found.'];
    error(msg);
end

%.. now all the data can be simply read in.
%.. sscanf scans down columns, so transpose cc before scanning
[data, nvalues, errmsg] = sscanf(cc', '%f', [ncol Inf]);
%.. now that the diagnostics have been recovered, transpose back.
data = data';

%.. error checking
if ~isempty(errmsg)
    fprintf('\nWARNING!\n');
    fprintf('     sscanf operating on %s\n', filename)
    fprintf('     threw the following error message:\n\n');
    fprintf('     %s\n\n', errmsg);
end

if rem(nvalues, ncol) ~= 0
    fprintf('\nWARNING!\n');
    fprintf('     sscanf operating on %s\n', filename)
    fprintf('     read in a partial data line.\n\n');
    fprintf('     Deleted last row of data.\n\n');
    %.. I've seen partial rows for AQD data; they were always the
    %.. last row.
    data(end, :) = [];
end

%.. calculate serial datenumbers from datevectors
time = datenum(data(:, [3 1 2 4 5 6]));
%.. delete these columns for ease of indexing
data(:, 1:6) = [];

%.. populate structure fields
eng.profile_date = nanmedian(time);  % [serial date number]
%.. x/0 -> Inf, 0/0 -> nan
eng.acquisition_rate_Hz_calculated = ...
    (length(time) - 1) / (86400 * (time(end) - time(1)));
eng.time = time;           %  [serial date number]
eng.current  = data(:,1);  %  [mA]
eng.voltage  = data(:,2);  %  [V]
eng.pressure = data(:,3);  %  [dbar]
eng.oxygen             = data(:,4);  % [uM] uncorrected for salinity and pressure
eng.optode_temperature = data(:,5);  % [degC]
eng.chl                = data(:,6);  % [counts]
eng.bback              = data(:,7);  % [counts]
eng.eco_temperature    = data(:,8);  % [counts]

eng.profile_mask = logical(eng.pressure);

eng.data_status = {'imported'};

return
%--------------------------------------------------------------------
