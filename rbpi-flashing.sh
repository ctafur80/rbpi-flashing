#!/usr/bin/env bash

# Script para flashear la imagen de Arch Linux para Raspberry Pi en una tarjeta microSD compatible

# Tiene que ejecutarse en versión de Bash de 4.0 en adelante, ya que hago uso de arrays asociativos


# Lo hago función porque nunca me acuerdo de las banderas que tengo que poner en read
sale () {
  echo "$1"
  read -n 1 -s -r -p "Presione cualquier tecla para continuar.
  "
  exit 1
}


# Almacena, en el arreglo asociativo curr_parts_in_ext_sd, en las claves, los designadores de las particiones del dispositivo externo (ojo, externo) en $1 (dados como kernel name descriptors; p.ej., /dev/sda), y, en los valores, las carpetas en las que se encuentran montadas
declare -A curr_parts_in_ext_sd=()
get_curr_parts_in_ext_sd () {
  # Comprobar que el argumento $1 es adecuado. Tiene que ser un dispositivo externo
  if [[ ! $1 =~ ^/dev/sd[a-z]$ ]] ; then
    sale "El nombre del dispositivo de almacenamiento introducido es incorrecto."
  fi

  local part_des=( $( systemd-mount --list | awk '{if(NR>1)print}' | awk -v myvar="^${1}" '$1 ~ myvar {print $1}' ) )

  for i in ${part_des[@]} ; do
    # TODO No logro averiguar el punto de montaje con systemd-mount. Creo que debería usar systemctl <loquesea>.mount
    curr_parts_in_ext_sd+=( [$i]="$( lsblk -lf $i | awk '{if(NR>2)print}' | awk '{print $7}' )" )
  done
}


# Desmonta todas las particiones que se encuentren montadas del dispositivo de almacenamiento externo en $1. El argumento se da en forma de kernel name descriptor (p.ej., /dev/sda)
unmount_parts_in_ext_sd () {
  # No necesito hacer comprobación del argumento, pues la hace la función get_curr_parts_in_ext_sd
  get_curr_parts_in_ext_sd $1

  local rev_ordered_parts=( $( echo "${!curr_parts_in_ext_sd[@]}" | tr " " "\n" | sort -n -r -k9 ) )
  # Desmonto, de la última a la primera, las particiones de $1 que estén montadas
  for i in ${rev_ordered_parts[@]} ; do
    if [[ -n ${curr_parts_in_ext_sd[$i]} ]] ; then
      systemd-mount -u $i
      curr_parts_in_ext_sd[$i]=""
    fi
  done

  get_curr_parts_in_ext_sd $1
  # TODO Comprobación
  for i in ${curr_parts_in_ext_sd[@]} ; do
    if [[ -n ${curr_parts_in_ext_sd[$i]} ]] ; then
      sale "No se han desmontado todas las particiones del volumen $1. Se ha producido un error." 
    fi
  done
}



# Aquí comienzan las constantes
# -----------------------------------------------------------------------------

HW_VERSION="3" # Opciones: 1, 2, 3 y 4
HW_MODEL="B" # Opciones: A y B

# Solo pueden tener sistema operativo de 64 bits las versiones 3 y 4 de hardware
ARCH="64" # Opciones: 32 y 64


declare -A VERS_AND_ARCH_X_ISO=(
  ["1_32"]="ArchLinuxARM-rpi-latest.tar.gz"
  ["2_32"]="ArchLinuxARM-rpi-2-latest.tar.gz"
  ["3_32"]="ArchLinuxARM-rpi-2-latest.tar.gz"
  ["3_64"]="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
  ["4_32"]="ArchLinuxARM-rpi-4-latest.tar.gz"
  ["4_64"]="ArchLinuxARM-rpi-aarch64-latest.tar.gz"
)

hw_vers_arch_comb="${HW_VERSION}_${ARCH}"

if [[ "${!VERS_AND_ARCH_X_ISO[@]}" =~ "${hw_vers_arch_comb}" ]] ; then
  sale "La versión de hardware $HW_VERSION no cuenta con sistema operativo de 64 bits."
fi

OS_ISO_FILE="${VERS_AND_ARCH_X_ISO[$hw_vers_arch_comb]}"
ARCH_LINUX_ARM_REPO="http://os.archlinuxarm.org/os"

unset hw_vers_arch_comb

BASE_DIR="/root"

curr_dir="$BASE_DIR"

# TODO Comprobar que se está ejecutando desde la carpeta base


read -n 1 -s -r -p "
Inserte en algún puerto externo (SD, USB, etc.) la tarjeta microSD que va a
flashear. Luego, presione cualquier tecla para continuar.

"


# TODO Quizás, se podría hacer sin preguntar, identificando la unidad que se
# acaba de conectar
lsblk
read -p "
El dispositivo donde está la tarjeta microSD que acaba de insertar está en
/dev/sdX. ¿Qué letra es esa X? " dev_letter

while ! [[ "$dev_letter" =~ ^[a-z]$ ]] ; do 
  read -p "
  El valor introducido no es válido. Debe ser un valor entre 'a' y 'z'. Vuelva
  a introducirlo." dev_letter
done

mount_dev="/dev/sd${dev_letter}"



unmount_parts_in_ext_sd $mount_dev


# La clave indica el designador de la partición, en forma de kernel name descriptor (p.ej., /dev/sda1). El valor, la carpetas en la que se monta. Solo puede tener 3 o 4 particiones
declare -A OS_DEVICE_PARTS=(
  ["${mount_dev}1"]="/boot"
  ["${mount_dev}2"]="/"
  ["${mount_dev}3"]="/home"
  # ["${mount_dev}4"]="/mnt/downloads"
)



# Creación de particiones

BOOT_PART_SIZE="+200M"
ROOT_PART_SIZE="+8G"

# Forma la secuencua que pasaré a Fdisk. Lo hago así porque Fdisk nos obliga a entrar y actuar desde dentro
create_fdisk_seq () {
  # TODO Resolver eso de que me pregunta confirmación con Y
  # parts_no_linux=( $( systemd-mount --list | tail -n +2 | grep ^$mount_dev | awk '$5 != "ext4" {print $1} ' ) )
  fdisk_seq=""

  get_curr_parts_in_ext_sd $mount_dev
  # Eliminamos todas las particiones
  for i in $( seq 1 +1 ${#curr_parts_in_ext_sd[@]} ) ; do
    fdisk_seq+="d"$'\n'$'\n'
  done

  # Elimina la tabla de particiones
  fdisk_seq+="o"$'\n'

  # Crea la partición 1; la de /boot
  fdisk_seq+="n"$'\n'"p"$'\n'"1"$'\n'$'\n'"${BOOT_PART_SIZE}"$'\n'"Y"$'\n'

  # if [[ "${parts_no_linux[@]}" =~ "${mount_dev}1" ]] ; then
  #   fdisk_seq+="Y"$'\n'
  # fi

  # Creamos la partición 2; la de /
  fdisk_seq+="n"$'\n'"p"$'\n'"2"$'\n'$'\n'"${ROOT_PART_SIZE}"$'\n'"Y"$'\n'

  # if [[ "${parts_no_linux[@]}" =~ "${mount_dev}2" ]] ; then
  #   fdisk_seq+="Y"$'\n'
  # fi

  # Crea la partición 3; la de /home
  if [[ ${#OS_DEVICE_PARTS[@]} -eq 4 ]] ; then
    if [[ "${OS_DEVICE_PARTS[${mount_dev}4]}" -eq "/mnt/downloads" ]] ; then
      HOME_PART_SIZE="+3G" 
    fi
  else
    HOME_PART_SIZE=""
  fi

  fdisk_seq+="n"$'\n'"p"$'\n'"3"$'\n'$'\n'"${HOME_PART_SIZE}"$'\n'"Y"$'\n'

  # if [[ "${parts_no_linux[@]}" =~ "${mount_dev}3" ]] ; then
  #   fdisk_seq+="Y"$'\n'
  # fi

  # Crea, en caso necesario, la partición 4
  if [[ ${#OS_DEVICE_PARTS[@]} -eq 4 ]] ; then
    fdisk_seq+="n"$'\n'"p"$'\n'"4"$'\n'$'\n'"${PART_4_SIZE}"$'\n'
  fi

  # Doy a la partición 1 la firma de FAT
  fdisk_seq+="t"$'\n'"1"$'\n'"c"$'\n'

  # Hace que la configuración tenga efecto
  fdisk_seq+="w"$'\n'
}

create_fdisk_seq
# Ahora, la variable fdisk_seq tiene almacenada la secuencia que se pasará a fdisk

# TODO Comprobación
echo "La variable fdisk_seq vale: ${fdisk_seq}" ; echo ""
# sale "Esto es solo una comprobación."

# Ahora ejecutamos la secuencia realmente
fdisk $mount_dev <<- EOF
${fdisk_seq}
EOF

# sale "Esto es solo una comprobación."

unmount_parts_in_ext_sd $mount_dev

yes | mkfs --type vfat ${mount_dev}1
yes | mkfs --type ext4 ${mount_dev}2
yes | mkfs --type ext4 ${mount_dev}3

[[ ${#OS_DEVICE_PARTS[@]} -eq 4 ]] && yes | mkfs --type ext4 ${mount_dev}4


unmount_parts_in_ext_sd $mount_dev

# sale "Esto es solo una comprobación."

# TODO Comprobación
systemd-mount --list
read -n 1 -s -r -p "
Compruebe que las particiones se han configurado como deseaba. Luego, presione
cualquier letra para continuar.

"

# Comprobación
get_curr_parts_in_ext_sd $mount_dev
if [[ ${#OS_DEVICE_PARTS[@]} -ne ${#curr_parts_in_ext_sd[@]} ]] ; then
  sale "Ha habido un error. El número de particiones es ahora
  ${#curr_parts_in_ext_sd[@]} cuando debería ser ${#OS_DEVICE_PARTS[@]}."
fi


[[ -d ${curr_dir}/boot ]] && rm -rf ${curr_dir}/boot
mkdir ${curr_dir}/boot

[[ -d ${curr_dir}/root ]] && rm -rf ${curr_dir}/root
mkdir ${curr_dir}/root


systemd-mount ${mount_dev}1 ${curr_dir}/boot
systemd-mount ${mount_dev}2 ${curr_dir}/root

[[ ! -f $OS_ISO_FILE ]] && wget ${ARCH_LINUX_ARM_REPO}/$OS_ISO_FILE


if [[ "$( whoami )" != "root" ]] ; then
  sale "Se ha producido un error. Este script debe ejecutarlo el usuario root."
fi

# Ahora realiza realmente el flasheo
bsdtar -xpf ${OS_ISO_FILE} -C root
sync

mv ${curr_dir}/root/boot/* ${curr_dir}/boot/

# Comprueba que la partición root está montada
get_curr_parts_in_ext_sd $mount_dev
if [[ ${curr_parts_in_ext_sd["${mount_dev}1"]} != "${curr_dir}/root" ]] ; then
  "Se ha producido un error. Ahora, la partición ${mount_dev}2 debería estar montada en /root."
fi

# TODO Lo quitaré
read -n 1 -s -r -p "
Comrpuebe si está montado /dev/sdX2, pues ahora vamos a habilitar sesión SSH por root.
"

# Permito acceso por SSH a la cuenta root
sed -i "/^#PermitRootLogin prohibit-password$/s/^#//" ${curr_dir}/root/etc/ssh/sshd_config
sed -i "/^PermitRootLogin prohibit-password$/s/prohibit-password$/yes/" ${curr_dir}/root/etc/ssh/sshd_config


# TODO Copiar los demás scripts en el directorio de root del sistema nuevo.
# Está pendiente de cómo lo voy a llamar finalmente
cp -r ${curr_dir}/rbpi-config ${curr_dir}/root/root/


read -n 1 -s -r -p "
Ahora, cambie en los archivos del script de instalación los valores de las
constantes de acuerdo con el tipo de sistema que desea tener. Tenga en cuenta
el número de particiones que ha creado en el flasheo.
"


unmount_parts_in_ext_sd $mount_dev

rm -rf ${curr_dir}/boot
rm -rf ${curr_dir}/root

lsblk
printf "
Ya ha concluido el proceso de flasheado de la tarjeta microSD que tendrá el
sistema operativo de su sistema. Compruebe que las particiones de la unidad
$mount_dev se encuentran ahora desmontadas. Si es así, extraiga entonces esa
tarjeta e introdúzcala en la ranura de la Raspberry Pi donde se usará. Conecte
también el cable de red Ethernet. Inicie el sistema, es decir, conéctelo a la
corriente eléctrica. Luego, entre como root (contraseña: root) a la carpeta
/root y ejecute el script de instalación /root/rbpi-config/install.sh.

"



