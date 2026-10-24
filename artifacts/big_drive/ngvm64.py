# the reference with a 64 MB drive window, for an experiment only
import sys
sys.path.insert(0, '/Users/scottmoschella/work/n-gage/tools/ngvm')
import ngvm
ngvm.NGVM_DRIVE_MAX = 64 << 20
sys.argv[0] = 'ngvm.py'
ngvm.main()
