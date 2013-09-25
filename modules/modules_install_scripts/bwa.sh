

###################
################### BWA
###################
# tpx patch can be found here:
# ftp://ftp.conveysupport.com/outgoing/bwa/bwa-0.6.2-tpx.patch
VERSION="0.7.5a"
INSTALL_PATH=$MUGQIC_INSTALL_HOME/software/bwa/
mkdir -p $INSTALL_PATH
cd $INSTALL_PATH

# Download
wget http://downloads.sourceforge.net/project/bio-bwa/bwa-$VERSION.tar.bz2
tar xvjf bwa-$VERSION.tar.bz2
chmod -R g+w bwa-$VERSION

# Compile
cd bwa-$VERSION
make -j8
cd ..

# Module file
echo "#%Module1.0
proc ModulesHelp { } {
       puts stderr \"\tMUGQIC - BWA \"
}
module-whatis \"MUGQIC - BWA  \"
            
set             root               \$::env(MUGQIC_INSTALL_HOME)/software/bwa/bwa-$VERSION
prepend-path    PATH               \$root
" > $VERSION

# version file
echo "#%Module1.0
set ModulesVersion \"$VERSION\"
" > .version

mkdir -p $MUGQIC_INSTALL_HOME/modulefiles/mugqic/bwa
mv .version $VERSION $MUGQIC_INSTALL_HOME/modulefiles/mugqic/bwa/
rm bwa-$VERSION.tar.bz2

