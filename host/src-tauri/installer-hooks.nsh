; Hook installer NSIS untuk Decky Host.
;
; Decky mendengarkan di TCP 8787 supaya HP di jaringan yang sama bisa
; menyambung. Tanpa aturan firewall, Windows memblokir koneksi masuk itu diam-
; diam: HP menemukan host lewat mDNS, lalu koneksinya timeout tanpa penjelasan.
; Installer berjalan dengan hak admin, jadi di sinilah tempat yang tepat untuk
; memasangnya — bukan membebani user dengan perintah netsh.
;
; Aturan dibatasi ke profil private dan domain. Di jaringan publik — kafe,
; bandara — Decky sengaja tidak bisa dijangkau.

!macro NSIS_HOOK_POSTINSTALL
  DetailPrint "Memasang aturan Windows Firewall untuk port 8787..."
  ; Hapus dulu supaya pemasangan ulang tidak menumpuk aturan duplikat.
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Decky Host"'
  Pop $0
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="Decky Host" dir=in action=allow protocol=TCP localport=8787 profile=private,domain'
  Pop $0
  ${If} $0 != 0
    ; Bukan alasan untuk menggagalkan instalasi: jalur USB tetap jalan, dan
    ; user bisa menambahkan aturannya sendiri nanti.
    DetailPrint "Aturan firewall gagal dipasang (kode $0). Jalur Wi-Fi mungkin terblokir."
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  DetailPrint "Menghapus aturan Windows Firewall Decky..."
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="Decky Host"'
  Pop $0
!macroend
