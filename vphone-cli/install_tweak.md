SSH in:                                                                                               
  sshpass -p alpine ssh -p 22222 root@192.168.65.32
                                                                                                        
  Set PATH first (run this after SSH):
  export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH  

  Common commands:

  # Update package lists
  apt-get update

  # Search for a package
  apt-cache search <name>

  # Show package info/versions
  apt-cache policy <package>

  # Install a package
  apt-get install -y --allow-unauthenticated <package>

  # Remove a package
  apt-get remove <package>

  # Install a .deb file directly
  dpkg -i /path/to/file.deb

  # List installed packages
  dpkg -l

  # Install an IPA via TrollStore
  /Applications/TrollStoreLite.app/trollstorehelper install /path/to/app.ipa

  # Force install IPA (overwrite system apps)
  /Applications/TrollStoreLite.app/trollstorehelper install force /path/to/app.ipa

  # Refresh app icons after install
  uicache -a

  Upload files to the VM (from your Mac):
  base64 -i /path/to/local/file | sshpass -p alpine ssh -p 22222 root@192.168.65.32 "export
  PATH=/var/jb/usr/bin:\$PATH; base64 -d > /var/mobile/Media/Books/file.ipa"

  The Sileo GUI issue is that it uses posix_spawn with persona attributes to escalate to root, which
  fails on PCC (returns EPERM). It never falls back to giveMeRoot. Fixing it would require patching the
  Sileo binary itself to skip persona spawn and use giveMeRoot directly.