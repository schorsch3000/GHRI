# GitHubReleaseInstaller
## what it does
Download the latest release of a github repo, post-process it and symlink it to some place in your `$PATH`.

## how it works

there is a config.yaml which contains some global configuration and package-config.
call `./ghri` to install all packages or `./ghri $packagename` to install a single package

## the config
### install_path (string)
It's the path where downloads are stored.
It may be a relative path to the directory of the script

### symlink_path (string)
It's the path where you executables will be symlinked to.
It may be a relative path to the directory of the script

### cache_path (string)
It's the path where github api call will be cached, to prevent api rate limiting
It may be a relative path to the directory of the script

### cache_lifetime_sec (string)
The cache lifetime in seconds, items older than this will be refreshed

### packages (array of objects)
Packages are defined here, package-options are:

#### slug (string) [mandatory]
String in the format `owner/repo` pointing to the github repository. The slug for the linux kernel would be torvalds/linux

#### name (String) [optional]
the name of the symlink, if not given the second part of the slug is used

#### asset_matcher (string) [optional]
A matcher to find the right asset of a given release.
It could either be a regular expression as it's given to `preg_match()` (including the delimiter eg.: `/^foo.*bar$/`)
or a glob as it is given to `fnmatch()`
every assets filename of the latest release is checkt against this matcher, if there is exactly one match, this asset is used
Defaults to `*` which works if only one asset ist given

#### post_process (array of object|string)
A list of postprocessors to make the asset ready for usage
If there is no further configuration given to postprocessor just give the name,
otherwise an object with at least a property named `name` to identify the processor and any configuration that's required by the processor

#### postprocessors:
##### bz2
bunzip2 a `bz2` file
no configuration available

##### gunzip
gunzip a gz file
no configuration available

##### link
set a symlink into `symlink_path` pointing to the processed asset with the package name as it's name

##### make_exec
make the asset executable (`0755`)

##### tar
untar a tar file
optional configuration value: `asset_matcher` to filter out the right file from the archive to feed to the next post processor, default is `*`

##### testrun
executes the linked asset to check it is executable, will fail if the exit code is != 0
optional parameters:

###### args (array of strings)
list of arguments given to the command, like `-v` or `--version`

###### quiet (bool)
configure if the output of the testrun is hidden, default: false
if the command is able to show it's version, or a small single line string that shows it's working use that.

##### unzip
unzip a zip file
optional configuration value: `asset_matcher` to filter out the right file from the archive to feed to the next post processor, default is `*`

##### xz
unpack a xz file
optional configuration value: `asset_matcher` to filter out the right file from the archive to feed to the next post processor, default is `*`




