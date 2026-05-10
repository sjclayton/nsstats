# Changelog

## [0.4.0](https://github.com/sjclayton/nsstats/compare/v0.3.0...v0.4.0) (2026-05-10)


### Features

* add API response validation and error handling ([c9aa638](https://github.com/sjclayton/nsstats/commit/c9aa6382fd635e8cf78396d77ec1daa48975a6ef))
* add cache miss % ([8437997](https://github.com/sjclayton/nsstats/commit/84379975486ff525c6674a997a651da766c26dbf))
* add CLI flag for checking version ([96ba042](https://github.com/sjclayton/nsstats/commit/96ba04248723f17bb0fc3370748388dfee275ce2))
* add DNS score metric and replace std deviation with 99th percentile RTT ([db2039e](https://github.com/sjclayton/nsstats/commit/db2039eeba1e40f5435aeb4c4ff80737551682ee))
* add extra metrics mode / CLI flag (resolver health, most used resolver) ([fef4539](https://github.com/sjclayton/nsstats/commit/fef45390835e2a907b08d52b30975289a7f43364))
* add HTTPS support ([ac51d69](https://github.com/sjclayton/nsstats/commit/ac51d697eeced7bc0315805e8ed1e7e230242c54))
* add mean (colored by delta), resolver health and overall impact metrics ([c9e3c04](https://github.com/sjclayton/nsstats/commit/c9e3c0432648b448008b626dccdbeebd5fbf7cab))
* add title heading and error handling for flags ([6ccb0b5](https://github.com/sjclayton/nsstats/commit/6ccb0b5cea4e522b6c8c29a6b5adf35c27c2d6f4))
* add TOML config file support with XDG compliance ([dc40df6](https://github.com/sjclayton/nsstats/commit/dc40df672c6eddf7616644a45453b87b016d0d53))
* add weekly stats flag and usage help ([598eee9](https://github.com/sjclayton/nsstats/commit/598eee99c1f5e8dffe2ed59a5e83374c7385c3ce))
* display average (as median), add std deviation ([3171222](https://github.com/sjclayton/nsstats/commit/31712220eba82ee8a2be99ed68ccbbf9a0512625))


### Bug Fixes

* align query logs fetched to time (hour and minute) respectively ([d2177dc](https://github.com/sjclayton/nsstats/commit/d2177dc1e8be82cac0ae22a5219e402242d2897e))
* align stabilityPenalty closer to real-world performance characteristics ([e958b2f](https://github.com/sjclayton/nsstats/commit/e958b2f68feb999aca721ff6883ccfe1c1aa2a0d))
* improve error handling for missing config fields ([0284ef8](https://github.com/sjclayton/nsstats/commit/0284ef86191d2874de4da9ee6f3fdcd488575acc))
* remove unnecessary error handling for unused API feature ([8c9fee7](https://github.com/sjclayton/nsstats/commit/8c9fee75768907eff58797d9b473cc4fbef00552))

## [0.3.0](https://github.com/sjclayton/nsstats/compare/v0.2.2...v0.3.0) (2026-05-10)


### Features

* add extra metrics mode / CLI flag (resolver health, most used resolver) ([fef4539](https://github.com/sjclayton/nsstats/commit/fef45390835e2a907b08d52b30975289a7f43364))
