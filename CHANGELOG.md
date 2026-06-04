# Changelog

## [0.4.0](https://github.com/sjclayton/nsstats/compare/v0.3.4...v0.4.0) (2026-06-04)


### Features

* Left-align title and show connected servers hostname in header ([db55f28](https://github.com/sjclayton/nsstats/commit/db55f288b21ba32fa0ca5d5d38bc615e57b60726))
* Show actual jitter value in Extra Metrics (replaces Resolver Health) ([b6b123c](https://github.com/sjclayton/nsstats/commit/b6b123c79c721b22487b18ec7a606a0a1fbd1f54))

## [0.3.4](https://github.com/sjclayton/nsstats/compare/v0.3.3...v0.3.4) (2026-05-20)


### Bug Fixes

* `recursiveWeight` now uses true recursive count (upstream only) ([e261eeb](https://github.com/sjclayton/nsstats/commit/e261eebaac59031322193f1c98be22d9a8ebb5cc))


### Performance Improvements

* optimize resolver lookup by reducing redundant table searches ([69e142e](https://github.com/sjclayton/nsstats/commit/69e142e415c05d6fa3a8244f149ca98ba30042ea))

## [0.3.3](https://github.com/sjclayton/nsstats/compare/v0.3.2...v0.3.3) (2026-05-13)


### Bug Fixes

* re-align resolver attribution to previous behaviour ([81fe0b6](https://github.com/sjclayton/nsstats/commit/81fe0b6ca7788570783ab2f1e9982499e01932a8))

## [0.3.2](https://github.com/sjclayton/nsstats/compare/v0.3.1...v0.3.2) (2026-05-13)


### Performance Improvements

* convert `uniqueQueries` from sequence to HashSet ([fc13b7c](https://github.com/sjclayton/nsstats/commit/fc13b7cb0fe84761bb6535812edcf2611ee12ae6))
* optimize resolver attribution and reduce API calls ([ef6cb55](https://github.com/sjclayton/nsstats/commit/ef6cb55e2bc8c177b739939dabcb28c5e6c7ad29))

## [0.3.1](https://github.com/sjclayton/nsstats/compare/v0.3.0...v0.3.1) (2026-05-10)


### Bug Fixes

* spinner initialization time (remove delay) ([aa486cf](https://github.com/sjclayton/nsstats/commit/aa486cf8c7a07bb1df4840bad06f81ec7841594f))

## [0.3.0](https://github.com/sjclayton/nsstats/compare/v0.3.0...v0.3.0) (2026-05-10)

### Features

- add extra metrics mode / CLI flag (resolver health, most used resolver) ([fef4539](https://github.com/sjclayton/nsstats/commit/fef45390835e2a907b08d52b30975289a7f43364))
