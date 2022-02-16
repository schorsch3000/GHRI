<?php
namespace GHRI;
use function fnmatch;
use function preg_match;
use function var_dump;

class Matcher
{
    private $matcher;
    public static function createFromString($matchString)
    {
        if (preg_match("/^\/.*\/[a-zA-Z]*$/", $matchString)) {
            return self::createFromRegex($matchString);
        }
        return self::createFromFnmatch($matchString);
    }
    public function __invoke($string)
    {
        return $this->match($string);
    }

    public function match($string)
    {
        $matcher = $this->matcher;
        return $matcher($string);
    }
    public static function createFromRegex($regex)
    {
        return new Matcher(function ($string) use ($regex) {
            return (bool) preg_match($regex, $string);
        });
    }
    public static function createFromFnmatch($pattern)
    {
        return new Matcher(function ($string) use ($pattern) {
            return fnmatch($pattern, $string);
        });
    }
    protected function __construct($matcher)
    {
        $this->matcher = $matcher;
    }
}
