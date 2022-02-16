<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function basename;
use function is_link;
use function realpath;
use function symlink;
use function unlink;

class Link extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        $link = $this->config['symlink_path'] . '/' . $this->package['name'];
        $this->package['link'] = $link;
        $target = realpath($asset->getName());
        if (is_link($link)) {
            unlink($link);
        }
        return symlink($target, $link);
    }
}
