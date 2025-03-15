#!/usr/bin/env sh

for dep in lua luarocks curl; do
	if ! command -v $dep >/dev/null; then
		echo "Missing dependency: $dep"
	fi
done
for dep in luafilesystem luv cjson sha1; do
	luarocks show $dep >/dev/null || luarocks install $dep
done
[ -f external/pkman.lua ] && exit
curl --silent https://raw.githubusercontent.com/moltzaum/pkman/refs/heads/master/pkman.lua > tools/pkman.lua && {
	echo "[pkman] File downloaded, bootstrap complate"
}
