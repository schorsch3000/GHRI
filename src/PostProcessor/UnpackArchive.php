<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use GHRI\Matcher;
use function arrayDefault;
use function escapeshellarg;
/**
 * @SuppressWarnings(PHPMD.StaticAccess)
 */
abstract class UnpackArchive extends APostProcessor
{
    public function processArchive(GithubAsset &$asset, $command)
    {
        arrayDefault($this->postProcessor, 'asset_matcher', '*');
        ob_start();
        system('2>&1 ' . $command, $retval);
        if (0 !== $retval) {
            fatal(
                "Error unpacking with command $command, exit code is $retval"
            );
        }
        $fileHandle = popen(
            'find . -type f -not -name ' . escapeshellarg($asset->getName()),
            'r'
        );
        $newPossibleAssets = [];
        while ($fileHandle && !feof($fileHandle)) {
            $possibleAsset = substr(fgets($fileHandle, 1024), 2, -1); // 2 removes ./ -1 removes newline
            if (!strlen($possibleAsset)) {
                continue;
            }
            $matcher = Matcher::createFromString(
                $this->postProcessor['asset_matcher']
            );
            if (!$matcher($possibleAsset)) {
                continue;
            }
            $newPossibleAssets[] = $possibleAsset;
        }
        if (1 == count($newPossibleAssets)) {
            $asset->setName(array_shift($newPossibleAssets));
            $this->infotext = ob_get_clean();
            return true;
        }
        if (count($newPossibleAssets)) {
            fatal(
                '    there are multiple matching assets: ' .
                    implode(', ', $newPossibleAssets)
            );
        }
        fatal('    no matching asset found');
    }
}
