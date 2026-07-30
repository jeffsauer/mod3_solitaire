# mod3_solitaire

<img width="1596" height="1256" alt="Screenshot 2026-07-23 at 8 17 26 AM" src="https://github.com/user-attachments/assets/dba0242f-d85b-4bec-8521-a145eb24d76b" />

AI generated V language port of the popular Mod3 variation from KDE kpatience

## Compiling

Follow instructions on vlang.io website to install the v compiler and toolchain for your platform

```
mkdir Development
cd Development
git clone https://github.com/jeffsauer/mod3_solitaire
cd mod3_solitaire
v mod3.v
```

Then, just run the executable:
```
./mod3
```

## NOTES

When compiled, the card images and sounds are embedded into the executable.  So, the executable should be self contained.

However, on macOS, I haven't been able to figure out how to statically link in the garbage collection library.  Best I could come up with is to install the Boehm gargage collector via homebrew, and then make sure homebrew's lib directory is in your library path:

```
brew install bdw-gc
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:$DYLD_LIBRARY_PATH"
```

This is only needed if your are simply distributing the executable to other machines.  If you build on that machine, the v toolchain already includes the needed libraries.
