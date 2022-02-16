<?php

use Colors\Color;

/**
 * @SuppressWarnings(PHPMD.ExitExpression)
 */

function fatal()
{
    global $color;
    /** @var Color $color */

    fwrite(
        STDERR,
        $color('ERROR: ' . implode(' ', func_get_args()) . "\n")->error
    );
    die(1);
}
