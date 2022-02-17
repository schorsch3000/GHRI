.PHONY: check setup phpstan fix prettier prettier-check prettier-fix phpmd clean release

export PATH := vendor/bin:node_modules/.bin:$(PATH)


release: fix check clean box src/func.php
	composer install --no-dev --optimize-autoloader
	./box compile


box:
	wget -c https://github.com/box-project/box/releases/download/3.15.0/box.phar -O box
	chmod +x box

setup: vendor src/func.php



src/func.php: $(wildcard src/func/*.php)
	echo "<?php" >src/func.php
	find src/func/ -type f -name "*.php" | sed 's/.*/require __DIR__."\/..\/\0";/' >>src/func.php


vendor: composer.json
	composer install
	touch vendor


fix: prettier-fix

prettier-fix: prettier
	prettier -w --trailing-comma-php=all --single-quote=true \
		*.php \
		src/*.php \
		src/**/*.php

check: phpstan phpmd prettier-check


prettier-check: prettier
	prettier -c --trailing-comma-php=all --single-quote=true \
		*.php \
		src/*.php \
		src/**/*.php

prettier: node_modules/.bin/prettier node_modules/@prettier/plugin-php


node_modules/@prettier/plugin-php:
	npm i @prettier/php-plugin
	touch node_modules/@prettier/plugin-php

node_modules/.bin/prettier:
	npm i prettier
	touch node_modules/.bin/prettier

vendor/bin/phpstan:
	rm -rf vendor
	make setup
vendor/bin/phpmd:
	rm -rf vendor
	make setup
phpstan: vendor/bin/phpstan
	phpstan analyse --level 5 -a vendor/autoload.php -- *.php src

phpmd: vendor/bin/phpmd
	phpmd ghri.php,src text cleancode,codesize,controversial,design,naming,unusedcode

clean:
	rm -rf node_modules vendor box src/func.php ghri.phar
