<?php

namespace GHRI\PostProcessor;

abstract class APostProcessor implements IPostProcessor
{
    protected $postProcessor;
    protected $package;
    protected $config;
    protected $infotext;

    /**
     * @param array $postProcessor
     * @param array $package
     * @param array $config
     */
    public function __construct(
        array $postProcessor,
        array &$package,
        array $config
    ) {
        $this->postProcessor = $postProcessor;
        $this->package = &$package;
        $this->config = $config;
    }

    public function getInfotext()
    {
        return $this->infotext;
    }
}
