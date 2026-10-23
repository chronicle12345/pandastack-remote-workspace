"""Point Openbox menu entries at the programs installed in this App."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

system_menu = Path('/etc/xdg/openbox/menu.xml')
target = system_menu if '--system' in sys.argv else Path.home() / '.config/openbox/menu.xml'
source = target if target.exists() else system_menu
tree = ET.parse(source)
browser_fixed = terminal_fixed = False
for item in tree.iter():
    if item.tag.rsplit('}', 1)[-1] != 'execute':
        continue
    if (item.text or '').strip() == 'x-www-browser':
        item.text = '/usr/local/bin/pds-open-browser'
        browser_fixed = True
    elif (item.text or '').strip() == 'x-terminal-emulator':
        item.text = 'xterm -fa "DejaVu Sans Mono" -fs 12 -e /bin/bash -lc "cd /workspace; exec bash"'
        terminal_fixed = True
target.parent.mkdir(parents=True, exist_ok=True)
tree.write(target, encoding='utf-8', xml_declaration=True)
print('browser-menu-configured=' + str(browser_fixed))
print('terminal-menu-configured=' + str(terminal_fixed))
