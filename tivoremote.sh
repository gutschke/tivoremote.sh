#!/bin/bash

export LC_ALL=en_US.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TIVO_CTRL="${1:-tivo} 31339"

getkey() {
  (
    trap 'stty echo icanon 2>/dev/null' EXIT INT TERM QUIT HUP
    stty -echo -icanon 2>/dev/null
    if [ $# -eq 0 ]; then
      dd count=1 bs=1 2>/dev/null
    else
      timeout --foreground "$1" dd count=1 bs=1 2>/dev/null
    fi
  )
}

chr() {
  printf "\\$(printf '%03o' "$1")"
}

ord() {
  printf '%d' $(printf '%c' "$1" | od -tu1 -An)
}

tivo() {
  # Send one or more commands to the TiVo.
  #
  # Available commands are:
  #   TELEPORT { TIVO | LIVETV | GUIDE | NOWPLAYING }
  #   SETCH <CHANNEL>
  #   FORCECH <CHANNEL>
  #   IRCODE { UP | DOWN | LEFT | RIGHT | SELECT | TIVO | LIVETV | THUMBSUP |
  #            THUMBSDOWN | CHANNELUP | CHANNELDOWN | RECORD | DISPLAY |
  #            NUM{0..9} | ENTER | CLEAR | PLAY | PAUSE | SLOW | FORWARD |
  #            REVERSE | STANDBY | NOWSHOWING | REPLAY | ADVANCE | DELIMITER |
  #            GUIDE | INFO | WINDOW | DIRECTV | STOP | CC_ON | CC_OFF |
  #            {A..Z} | MINUS | EQUALS | LBRACKET | RBRACKET | BACKSLASH |
  #            SEMICOLON | QUOTE | COMMA | PERIOD | SLASH | BACKQUOTE | SPACE |
  #            CAPS | LSHIFT | RSHIFT | LCONTROL | RCONTROL | LMETA | RMETA |
  #            KBDUP | KBDDOWN | KBDLEFT | KBDRIGHT | PAGEUP | PAGEDOWN | HOME |
  #            INSERT | BACKSPACE | DELETE | KBDENTER | ESCAPE |
  #            VIDEO_MODE_{NATIVE|FIXED_{480i|480p|720p|1080i}|
  #                        HYBRID|HYBRID_{720p|1080i}} |
  #            ASPECT_CORRECTION_{FULL|PANEL|ZOOM|WIDE_ZOOM} | EXIT }
  #
  # Returns (non-)zero status code.
  #
  # TiVo's network interface is a little limited. It seems to be designed for
  # interactive rather than programmatic use.
  #
  # Most commands don't output result codes unless there was an error executing
  # the command. But if there currently is life TV showing, we occasionally
  # receive unsolicited CH_STATUS updates about the currently active channel. We
  # try to determine progress by deliberately issuing invalid commands that have
  # well-known error messages. Also, some long-running commands cause the TiVo
  # to be busy and to drop subsequent commands. As much as possible, we
  # recognize this problem and inject delays.

  coproc /bin/nc ${TIVO_CTRL}

  rc=1
  eval '{ # Early failures are most likely problems with the network.
          msg="NOT CONNECTED"
          printf "?\r"
          tm=1
          while read -t ${tm} -d $'"'"'\r'"'"' status; do
            tm=.1

            # We expect to see "INVALID_COMMAND", but we might also
            # see "CH_STATUS".
            [ "${status}" != "INVALID_COMMAND" ] || break
          done
          if [ -n "${status}" ]; then
            # Process all command line arguments.
            msg=
            rc=
            while [ "$#" -gt 0 ]; do
              # Send the command followed by a command that we know will
              # trigger a well-defined error message.
              if [[ "$1" =~ ^"IRCODE" ]]; then
                printf "%s\rSETCH XXX\r" "$1"
                expect="CH_FAILED MALFORMED_CHANNEL"
              else
                printf "%s\rIRCODE XXX\r" "$1"
                expect="INVALID_KEY"
              fi

              # Even after waiting for the command to complete, there are
              # some long-running commands that can cause subsequent commands
              # to be dropped silently. Try to compensate.
              [[ "$1" =~ ^"TELEPORT " ]] && sleep .5
              [[ "$1" =~ ^"IRCODE TIVO" ]] && sleep .5
              [[ "$1" =~ ^"IRCODE LIVETV" ]] && sleep .5
              [[ "$1" =~ ^"IRCODE NOWSHOWING" ]] && sleep .5
              [[ "$1" =~ ^"IRCODE GUIDE" ]] && sleep .5
              shift

              # Wait for command to complete.
              tm=1
              while read -t ${tm} -d $'"'"'\r'"'"' status; do
                # "CH_STATUS" update messages can show up at (almost) any
                # time. The protocol does not provide for a good way to know
                # to expect and when not to expect them. Best option is to
                # simply ignore these messages.
                [[ "${status}" =~ ^"CH_STATUS " ]] && continue

                # If we try to switch to LIVETV while we are already showing
                # LIVETV, we get an error message. This is somewhat unusual,
                # as the protocol normally does not have these sort of
                # informative messages. It also does not really constitute an
                # error. We should ignore this message.
                [[ "${status}" =~ ^"LIVETV_" ]] && continue

                # If we see the expected error message, we know that our
                # command completed successfully.
                [ "${status}" != "${expect}" ] || break

                # Anything else and we have encountered a genuine error. Best
                # to abort execution at this point. That also ensures that we
                # will have to close the network connection, which resynchronizes
                # the command loop.
                rc=1
                msg="${status}"
                break 2
              done
            done
          fi; }'" <&${COPROC[0]} >&${COPROC[1]}"

  # Close the network connection.
  { kill ${COPROC_PID} && wait ${COPROC_PID} || :; } >&/dev/null

  # Print error message, if any.
  [ -z "${msg}" ] || echo "${msg}" >&2

  # Return exit code, if any.
  return $rc
}

keyboard() {
  local c="$1"
  local o="$(ord "${c}")"
  if [ "${o}" -ge 65 -a "${o}" -le 90 ]; then
    tivo "KEYBOARD LSHIFT"
    c="${c,,}"
    o=$((o+32))
  fi
  case "${c}" in
    -)   tivo "KEYBOARD MINUS";;
    =)   tivo "KEYBOARD EQUALS";;
    [)   tivo "KEYBOARD LBRACKET";;
    ])   tivo "KEYBOARD RBRACKET";;
    \\)  tivo "KEYBOARD BACKSLASH";;
    \;)  tivo "KEYBOARD SEMICOLON";;
    \')  tivo "KEYBOARD QUOTE";;
    ,)   tivo "KEYBOARD COMMA";;
    .)   tivo "KEYBOARD PERIOD";;
    /)   tivo "KEYBOARD SLASH";;
    \`)  tivo "KEYBOARD BACKQUOTE";;
    ' ') tivo "KEYBOARD SPACE";;
    *)   if [ "${o}" -ge 48 -a "${o}" -le 57 ]; then
           tivo "IRCODE NUM${c}"
         elif [ "${o}" -ge 97 -a "${o}" -le 122 ]; then
           tivo "KEYBOARD ${c^^}"
         fi;;
  esac
}

cat <<EOF
TIVO Remote Control
-------------------

T:      TiVo
N:      Now Showing
V:      Live TV
Arrows: Up/Down/Left/Right
SPC:    Select
I:      Info
G:      Guide
U:      Channel Up
D:      Channel Down
R:      Record
+:      Thumbs Up
-:      Thumbs Down
P:      Play
S:      Pause
Z:      Zoom
F:      Forward
R:      Reverse
W:      Slow
A:      Advance
B:      Back
C:      Clear
ENTER:  Enter/Last
0-9:    Number keys
F1:     Yellow (A)
F2:     Blue (B)
F3:     Red (C)
F4:     Green (D)
":      Enter Text

EOF

while :; do
  c="$(getkey | tr a-z A-Z)"
  if [ "${c}" = '' ]; then
    c="0a"
  elif [ "${#c}" != 1 -o $(ord "${c}") -le 32 -o $(ord "${c}") -gt 126 ]; then
    c="$(printf '%s' "${c}" | xxd -ps)"
    if [ "x${c}" = "x1b" ]; then
      while :; do
        d="$(getkey .1)" || break
        c="${c}$(printf '%s' "${d}" | xxd -ps)"
        d="$(ord "${d}")"
        [ ${d} -lt 48 -o ${d} -gt 59 -o "${d}" -eq 58 ] &&
          [ "${d}" -ne 91 -a "${d}" -ne 79 ] &&
          break
      done
    fi
  fi
  tput cr; tput el
  case "${c}" in
    T|1b5b48)            tivo "IRCODE TIVO";;
    N)                   tivo "IRCODE NOWSHOWING";;
    V)                   tivo "IRCODE LIVETV";;
    K|10|1b5b41)         tivo "IRCODE UP";;
    J|0e|1b5b42)         tivo "IRCODE DOWN";;
    L|06|1b5b43)         tivo "IRCODE RIGHT";;
    H|02|1b5b44)         tivo "IRCODE LEFT";;
    20)                  tivo "IRCODE SELECT";;
    I)                   tivo "IRCODE INFO";;
    G)                   tivo "IRCODE GUIDE";;
    U|1b5b357e)          tivo "IRCODE CHANNELUP";;
    D|1b5b367e)          tivo "IRCODE CHANNELDOWN";;
    R)                   tivo "IRCODE RECORD";;
    +)                   tivo "IRCODE THUMBSUP";;
    -)                   tivo "IRCODE THUMBSDOWN";;
    P)                   tivo "IRCODE PLAY";;
    S)                   tivo "IRCODE PAUSE";;
    Z)                   tivo "IRCODE WINDOW";;
    F)                   tivo "IRCODE FORWARD";;
    R)                   tivo "IRCODE REVERSE";;
    W)                   tivo "IRCODE SLOW";;
    A|1b5b46|09)         tivo "IRCODE ADVANCE";;
    B|1b)                tivo "IRCODE REPLAY";;
    C|1b5b337e)          tivo "IRCODE CLEAR";;
    0a)                  tivo "IRCODE ENTER";;
    0|1|2|3|4|5|6|7|8|9) tivo "IRCODE NUM${c}";;
    1b4f50)              tivo "IRCODE ACTION_A";;
    1b4f51)              tivo "IRCODE ACTION_B";;
    1b4f52)              tivo "IRCODE ACTION_C";;
    1b4f53)              tivo "IRCODE ACTION_D";;
    '"')                 read -r -p "Enter text: " txt
                         tput cuu 1
                         tput el
                         sed -e 's/./&\n/g' <<<"${txt}" |
                           while IFS= read -r c; do
                             keyboard "${c}"
                         done
                         ;;
  esac
done
