<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;

interface IPostProcessor
{
    public function __construct(
        array $postProcessor,
        array &$package,
        array $config
    );
    public function process(GithubAsset &$asset);
    public function getInfotext();
}
