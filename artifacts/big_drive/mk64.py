# mkdrive.py with the drive's ceiling at 64 MB, for an experiment only
import importlib.util, sys
spec = importlib.util.spec_from_file_location('mkdrive', '/Users/scottmoschella/work/n-gage/tools/mkdrive.py')
mk = importlib.util.module_from_spec(spec); spec.loader.exec_module(mk)
mk.MAX_MB = 64
sys.argv[0] = 'mkdrive.py'
mk.main()
