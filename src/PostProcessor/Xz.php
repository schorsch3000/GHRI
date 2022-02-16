<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;

/**
 * @SuppressWarnings(PHPMD.ShortClassName)
 */
class Xz extends UnpackArchive
{
    public function process(GithubAsset &$asset)
    {
        return $this->processArchive(
            $asset,
            'xz -d --force ' . escapeshellarg($asset->getName())
        );
    }
}
