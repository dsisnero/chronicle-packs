.PHONY: install update format lint test clean

install:
	shards install

update:
	shards update

format:
	crystal tool format src spec

lint:
	ameba src spec

test:
	crystal spec

clean:
	rm -rf temp/*
