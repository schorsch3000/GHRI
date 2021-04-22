# GitHubReleaseInstaller
## what it does
Download the latest release of a github repo, post-process it and symlink it to someplace in your `$PATH`.

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
String in the format owner/repo pointing to the github repository the slug for the linux kernel would be torvalds/linux

#### name (String) [optional]
the name of the symlink, if not given the second part of the slug is used

#### asset_matcher (string)
A matcher to find the right asset of a given release.
It could either be a regular expression as it's given to `preg_match()` (including the delimiter eg.: `/^foo.*bar$/`)
or a glob as it is given to `fnmatch()`
every assets filename of the latest release is scheckt against this matcher, if there is exactly one match, this asset is used

#### post_process (array of object|string)
A list of postprocessors to make the asset ready
if there is no further configuration given to postprocessor just give the name,
otherwise an object with at least a propertie named `name` to identify the processor and any configuration that's feed to the processor

#### postprocessors:
##### bz2
bunzip2 a `bz2` file
no configuration availible

##### gunzip
gunzip a gz file, no configuration availible

##### unzip
unzip a zip file
optional configuration value: `asset_matcher` to filter out the right file from the archive to feed to the next post processor, default is `/.*/`

##### tar
untar a tar file
optional configuration value: `asset_matcher` to filter out the right file from the archive to feed to the next post processor `/.*/`

##### make_executeable
make the asset executeable (`0755`)

##### link
set a symlink with the packages name as linkname to the asset

##### testrun
execute the linkes asset to check it is executeable, will fail if the returncode is != 0
optional parameters:

###### args (array of strings)
list of arguments feed to the command, likle `-v` or `--version`

###### quiet (bool)
configure if the output of the testrun is hidden, default: false
if the command is able to show it's version, or a small single line string that shows it's working use that.