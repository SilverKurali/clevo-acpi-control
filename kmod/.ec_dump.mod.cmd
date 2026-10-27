savedcmd_ec_dump.mod := printf '%s\n'   ec_dump.o | awk '!x[$$0]++ { print("./"$$0) }' > ec_dump.mod
