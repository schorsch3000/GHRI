<?php

namespace GHRI\DataStructure;

/**
 * @SuppressWarnings(PHPMD.CamelCasePropertyName)
 * @SuppressWarnings(PHPMD.TooManyFields)
 * @SuppressWarnings(PHPMD.ShortVariable)
 */
class GithubUploader extends SimpleDataStructure
{
    protected $login;
    protected $id;
    protected $node_id;
    protected $avatar_url;
    protected $gravatar_id;
    protected $url;
    protected $html_url;
    protected $followers_url;
    protected $following_url;
    protected $gists_url;
    protected $starred_url;
    protected $subscriptions_url;
    protected $organizations_url;
    protected $repos_url;
    protected $events_url;
    protected $received_events_url;
    protected $type;

    /**
     * @return mixed
     */
    public function getLogin()
    {
        return $this->login;
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
    public function getAvatarUrl()
    {
        return $this->avatar_url;
    }

    /**
     * @return mixed
     */
    public function getGravatarId()
    {
        return $this->gravatar_id;
    }

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
    public function getHtmlUrl()
    {
        return $this->html_url;
    }

    /**
     * @return mixed
     */
    public function getFollowersUrl()
    {
        return $this->followers_url;
    }

    /**
     * @return mixed
     */
    public function getFollowingUrl()
    {
        return $this->following_url;
    }

    /**
     * @return mixed
     */
    public function getGistsUrl()
    {
        return $this->gists_url;
    }

    /**
     * @return mixed
     */
    public function getStarredUrl()
    {
        return $this->starred_url;
    }

    /**
     * @return mixed
     */
    public function getSubscriptionsUrl()
    {
        return $this->subscriptions_url;
    }

    /**
     * @return mixed
     */
    public function getOrganizationsUrl()
    {
        return $this->organizations_url;
    }

    /**
     * @return mixed
     */
    public function getReposUrl()
    {
        return $this->repos_url;
    }

    /**
     * @return mixed
     */
    public function getEventsUrl()
    {
        return $this->events_url;
    }

    /**
     * @return mixed
     */
    public function getReceivedEventsUrl()
    {
        return $this->received_events_url;
    }

    /**
     * @return mixed
     */
    public function getType()
    {
        return $this->type;
    }
}
