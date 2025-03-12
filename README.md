# pkman

A **minimal Lua-based package manager for C++ projects**, inspired by Neovim
plugin managers.

`pkman` helps you **download**, **build**, and **manage** project dependencies
from source in an isolated `external/` directory. It's lightweight, extensible,
and easy to configure using Lua.

Maintainer's Note: This is not a professional tool. I intend to use it, but
prefer that it be a "one and done" project maintenance-wise.

Honestly, I'm unfamiliar with how dependencies in C++ are supposed to be
handled. I was thinking that with so many options (Conan, CPM.cmake, Hunter,
vcpkg), maybe they all suck at least a little? (-‿-")

My inspiration, aside from Neovim, was a document I found titled "The Pitchfork
Layout (PFL)". This framework made a lot of sense to me. I had recently also
heard about `build.zig`, which further drove the point that there isn't a single
preferred way of managing dependencies for C++ projects.

What I wanted:
- I wanted to organize my project using conventions outlined in the PFL
- I wanted to "make it easy" to get going with project sources I find on the internet
- I wanted the ability to configure the build
- I did NOT want to script in CMake, or bash

In the end, the tool has limitations compared to actual package managers, but it
shouldn't be an issue for me. I do not care about leveraging a central package
registry. Although binary distribution may reduce build times, build objects
should be cached, limiting any pain-points.

From my observation, building from source seems to be the common case when it
comes to managing dependencies. I have sometimes wanted to build a project off
the `master` branch as well.

Fair warning: I don't have good tests in general, nor do I know how it works on
Linux or Windows.

---

## Features

- [x] **Lua-based configuration** — Define dependencies in pure Lua
- [x] **Asynchronous downloading** — Parallel fetches via `luv`
- [x] **Local installs** — Dependencies installed in project-local directories

Tentative:
- [ ] **Flexible build system support** — `cmake`, `make`, `meson`, or custom
- [ ] **Cross-platform potential** — Primarily tested on macOS/Linux

---

## Limitations

❌ No Central Package Registry

No conan-center or vcpkg equivalent.

You need to manually specify Git URLs, refs, or hashes.

❌ No Binary Distribution / Caching

No binary cache means always building from source, which slows things down.

Conan and vcpkg support binary packages and shared caching across projects.

❌ Limited Testing for Platform Support and Build System Integration

Primarily tested on MacOS, expected to function similarly on Linux.

Windows support is unknown.

There are multiple build systems, but only CMake has been verified.

❌ No Dependency Resolution

Just include the version you need.

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Wishlist & Roadmap](#wishlist--roadmap)
- [License](#license)

---

## Installation

Ensure you have the following **system dependencies** installed:

| Dependency  | Description                        |
|-------------|------------------------------------|
| `lua`       | Lua interpreter (recommended 5.1+) |
| `luarocks`  | Lua package manager                |
| `curl`      | Used for bootstrapping `pkman`     |

Copy the `bootstrap_pkman.sh` file to your tools directory,

Then run the **bootstrap script**:
```
./tools/bootstrap_pkman.sh
```

This script will:
- Check for system dependencies
- Install Lua dependencies (`luafilesystem`, `luv`)
- Download the `pkman.lua` script into `external/pkman.lua`

---

## Quick Start

### 1. Create a `build.lua` file at your project root:
```
local pkman = require("external/pkman.lua")

pkman.setup({
  {
    'mosra/corrade',
    hash = '4ee45ba',
    build = {
      system = 'cmake',
      install = true,
      options = {
        '-DCMAKE_BUILD_TYPE=Release'
      },
      parallel = true,
    },
  },
  {
    url = 'https://github.com/mosra/magnum.git',
    hash = 'f9175d2',
    -- Alternatively, a branch or tag may be specified:
    -- refspec = 'v2020.06',
    build = {
      system = 'cmake',
      install = true,
      options = {
        '-DCMAKE_BUILD_TYPE=Release'
      },
      parallel = true,
    },
  },
})
```

### 2. Run the setup
```
lua build.lua
```

---

## How It Works

- Dependencies are declared as Lua tables (inspired by Neovim plugin managers)
- Git repositories are downloaded asynchronously into `./external/`
- Builds are performed **sequentially** to avoid race conditions
- Install paths are configurable (defaults to `<build_dir>/install`)

### Supported Build Systems

| System  | Status     |
|---------|------------|
| `cmake` | Stable     |
| `make`  | Untested   |
| `meson` | Untested   |
| `custom`| Unplanned  |

---

## Project Structure

```
project-root/
├── build.lua                 # Your dependency setup
├── external/
│   ├── pkman.lua             # The package manager
│   ├── <dependency>/         # Dependency source
│   └── <dependency-build>/   # Dependency build dir
├── tools/
│   └── bootstrap-pkman.sh    # Bootstrap script
└── README.md
```

---

## Wishlist & Roadmap

- [ ] Configurable `external` directory location.
- [ ] More robust support for `make` and `meson`
- [ ] Platform-specific testing (Linux, Windows).
- [ ] Better error handling? (Not certain how user-friendly it feels)

---

## License

MIT License © 2025 [Matthew Moltzau](https://github.com/moltzaum)
