<?php

namespace GHRI\DataStructure;

/**
 * @SuppressWarnings(PHPMD.CamelCasePropertyName)
 * @SuppressWarnings(PHPMD.ShortVariable)
 * @SuppressWarnings(PHPMD.TooManyFields)
 */
class GithubAsset extends SimpleDataStructure
{
    protected $url;
    protected $id;
    protected $node_id;
    protected $name;
    protected $label;
    protected $uploader;
    protected $content_type;
    protected $state;
    protected $size;
    protected $download_count;
    protected $created_at;
    protected $uploaded_at;
    protected $browser_download_url;

    /**
     * @return mixed
     */
    public function getUrl()
    {
        return $this->url;
    }

    /**
     * @return mixed
     */
    public function getId()
    {
        return $this->id;
    }

    /**
     * @return mixed
     */
    public function getNodeId()
    {
        return $this->node_id;
    }

    /**
     * @return mixed
     */
    public function getName()
    {
        return $this->name;
    }

    /**
     * @return mixed
     */
    public function getLabel()
    {
        return $this->label;
    }

    /**
     * @return mixed
     */
    public function getUploader()
    {
        return $this->uploader;
    }

    /**
     * @return mixed
     */
    public function getContentType()
    {
        return $this->content_type;
    }

    /**
     * @return mixed
     */
    public function getState()
    {
        return $this->state;
    }

    /**
     * @return mixed
     */
    public function getSize()
    {
        return $this->size;
    }

    /**
     * @return mixed
     */
    public function getDownloadCount()
    {
        return $this->download_count;
    }

    /**
     * @return mixed
     */
    public function getCreatedAt()
    {
        return $this->created_at;
    }

    /**
     * @return mixed
     */
    public function getUploadedAt()
    {
        return $this->uploaded_at;
    }

    /**
     * @return mixed
     */
    public function getBrowserDownloadUrl()
    {
        return $this->browser_download_url;
    }

    /**
     * @param mixed $name
     */
    public function setName($name)
    {
        $this->name = $name;
    }
}
