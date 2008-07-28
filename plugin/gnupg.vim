" Name: gnupg.vim
" Version:  $Id$
" Author:   Markus Braun <markus.braun@krawel.de>
" Summary:  Vim plugin for transparent editing of gpg encrypted files.
" Licence:  This program is free software; you can redistribute it and/or
"           modify it under the terms of the GNU General Public License.
"           See http://www.gnu.org/copyleft/gpl.txt
" Section: Documentation {{{1
" Description:
"   
"   This script implements transparent editing of gpg encrypted files. The
"   filename must have a ".gpg", ".pgp" or ".asc" suffix. When opening such
"   a file the content is decrypted, when opening a new file the script will
"   ask for the recipients of the encrypted file. The file content will be
"   encrypted to all recipients before it is written. The script turns off
"   viminfo and swapfile to increase security.
"
" Installation: 
"
"   Copy the gnupg.vim file to the $HOME/.vim/plugin directory.
"   Refer to ':help add-plugin', ':help add-global-plugin' and ':help
"   runtimepath' for more details about Vim plugins.
"
" Commands:
"
"   :GPGEditRecipients
"     Opens a scratch buffer to change the list of recipients. Recipients that
"     are unknown (not in your public key) are highlighted and have
"     a prepended "!". Closing the buffer makes the changes permanent.
"
"   :GPGViewRecipients
"     Prints the list of recipients.
"
"   :GPGEditOptions
"     Opens a scratch buffer to change the options for encryption (symmetric,
"     asymmetric, signing). Closing the buffer makes the changes permanent.
"     WARNING: There is no check of the entered options, so you need to know
"     what you are doing.
"
"   :GPGViewOptions
"     Prints the list of options.
"
" Variables:
"
"   g:GPGExecutable
"     If set used as gpg executable, otherwise the system chooses what is run
"     when "gpg" is called. Defaults to "gpg".
"
"   g:GPGUseAgent
"     If set to 0 a possible available gpg-agent won't be used. Defaults to 1.
"
"   g:GPGPreferSymmetric
"     If set to 1 symmetric encryption is preferred for new files. Defaults to 0.
"
"   g:GPGPreferArmor
"     If set to 1 armored data is preferred for new files. Defaults to 0.
"
" Credits:
" - Mathieu Clabaut for inspirations through his vimspell.vim script.
" - Richard Bronosky for patch to enable ".pgp" suffix.
" - Erik Remmelzwaal for patch to enable windows support and patient beta
"   testing.
" - Lars Becker for patch to make gpg2 working.
" - Thomas Arendsen Hein for patch to convert encoding of gpg output
" - Karl-Heinz Ruskowski for patch to fix unknown recipients and trust model
" - Giel van Schijndel for patch to get GPG_TTY dynamically.
"
" Section: Plugin header {{{1
if v:version < 700
  echohl ErrorMsg | echo 'plugin gnupg.vim requires Vim version >= 7' | echohl None
  finish
endif

if (exists("g:loaded_gnupg") || &cp || exists("#BufReadPre#*.\(gpg\|asc\|pgp\)"))
  finish
endif

let g:loaded_gnupg = "$Revision$"

" Section: Autocmd setup {{{1
augroup GnuPG
  autocmd!

  " initialize the internal variables
  autocmd BufNewFile,BufReadPre,FileReadPre      *.\(gpg\|asc\|pgp\) call s:GPGInit()
  " force the user to edit the recipient list if he opens a new file and public
  " keys are preferred
  autocmd BufNewFile                             *.\(gpg\|asc\|pgp\) if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 0) | call s:GPGEditRecipients() | endif
  " do the decryption
  autocmd BufReadPost,FileReadPost               *.\(gpg\|asc\|pgp\) call s:GPGDecrypt()

  " convert all text to encrypted text before writing
  autocmd BufWritePre,FileWritePre               *.\(gpg\|asc\|pgp\) call s:GPGEncrypt()
  " undo the encryption so we are back in the normal text, directly
  " after the file has been written.
  autocmd BufWritePost,FileWritePost             *.\(gpg\|asc\|pgp\) call s:GPGEncryptPost()
augroup END

" Section: Highlight setup {{{1
highlight default link GPGWarning WarningMsg
highlight default link GPGError ErrorMsg
highlight default link GPGHighlightUnknownRecipient ErrorMsg

" Section: Functions {{{1
" Function: s:GPGInit() {{{2
"
" initialize the plugin
"
function s:GPGInit()
  " first make sure nothing is written to ~/.viminfo while editing
  " an encrypted file.
  set viminfo=

  " we don't want a swap file, as it writes unencrypted data to disk
  set noswapfile

  " check what gpg command to use
  if (!exists("g:GPGExecutable"))
    let g:GPGExecutable = "gpg --trust-model always"
  endif

  " check if gpg-agent is allowed
  if (!exists("g:GPGUseAgent"))
    let g:GPGUseAgent = 1
  endif

  " check if symmetric encryption is preferred
  if (!exists("g:GPGPreferSymmetric"))
    let g:GPGPreferSymmetric = 0
  endif

  " check if armored files are preferred
  if (!exists("g:GPGPreferArmor"))
    let g:GPGPreferArmor = 0
  endif

  " check if debugging is turned on
  if (!exists("g:GPGDebugLevel"))
    let g:GPGDebugLevel = 0
  endif

  " print version
  call s:GPGDebug(1, "gnupg.vim ". g:loaded_gnupg)

  " determine if gnupg can use the gpg-agent
  if (exists("$GPG_AGENT_INFO") && g:GPGUseAgent == 1)
    if (!exists("$GPG_TTY") && !has("gui_running"))
      let $GPG_TTY = system("tty")
      if (v:shell_error)
        let $GPG_TTY = ""
        echohl GPGError
        echom "The GPG_TTY is not set and no TTY could be found using the `tty` command!"
        echom "gpg-agent might not work."
        echohl None
      endif
    endif
    let s:GPGCommand=g:GPGExecutable . " --use-agent"
  else
    let s:GPGCommand=g:GPGExecutable . " --no-use-agent"
  endif

  " don't use tty in gvim
  " FIXME find a better way to avoid an error.
  "       with this solution only --use-agent will work
  if has("gui_running")
    let s:GPGCommand=s:GPGCommand . " --no-tty"
  endif

  " setup shell environment for unix and windows
  let s:shellredirsave=&shellredir
  let s:shellsave=&shell
  if (match(&shell,"\\(cmd\\|command\\).exe") >= 0)
    " windows specific settings
    let s:shellredir = '>%s'
    let s:shell = &shell
    let s:stderrredirnull = '2>nul'
  else
    " unix specific settings
    let s:shellredir = &shellredir
    let s:shell = 'sh'
    let s:stderrredirnull ='2>/dev/null'
    let s:GPGCommand="LANG=C LC_ALL=C " . s:GPGCommand
  endif

  " find the supported algorithms
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --version")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  let s:GPGPubkey=substitute(output, ".*Pubkey: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCipher=substitute(output, ".*Cipher: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGHash=substitute(output, ".*Hash: \\(.\\{-}\\)\n.*", "\\1", "")
  let s:GPGCompress=substitute(output, ".*Compress: \\(.\\{-}\\)\n.*", "\\1", "")
endfunction

" Function: s:GPGDecrypt() {{{2
"
" decrypt the buffer and find all recipients of the encrypted file
"
function s:GPGDecrypt()
  " switch to binary mode to read the encrypted file
  set bin

  " get the filename of the current buffer
  let filename=escape(expand("%:p"), '\"')

  " clear GPGEncrypted, GPGRecipients, GPGUnknownRecipients and GPGOptions
  let b:GPGEncrypted=0
  let b:GPGRecipients=[]
  let b:GPGUnknownRecipients=[]
  let b:GPGOptions=[]

  " find the recipients of the file
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --verbose --decrypt --list-only --dry-run --batch --no-use-agent --logger-fd 1 \"" . filename . "\"")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  call s:GPGDebug(1, "output of command '" . s:GPGCommand . " --verbose --decrypt --list-only --dry-run --batch --no-use-agent --logger-fd 1 \"" . filename . "\"' is:")
  call s:GPGDebug(1, ">>>>> " . output . " <<<<<")

  " check if the file is symmetric/asymmetric encrypted
  if (match(output, "gpg: encrypted with [[:digit:]]\\+ passphrase") >= 0)
    " file is symmetric encrypted
    let b:GPGEncrypted=1
    call s:GPGDebug(1, "this file is symmetric encrypted")

    let b:GPGOptions+=["symmetric"]

    let cipher=substitute(output, ".*gpg: \\([^ ]\\+\\) encrypted data.*", "\\1", "")
    if (match(s:GPGCipher, "\\<" . cipher . "\\>") >= 0)
      let b:GPGOptions+=["cipher-algo " . cipher]
      call s:GPGDebug(1, "cipher-algo is " . cipher)
    else
      echohl GPGWarning
      echom "The cipher " . cipher . " is not known by the local gpg command. Using default!"
      echo
      echohl None
    endif
  elseif (match(output, "gpg: public key is [[:xdigit:]]\\{8}") >= 0)
    " file is asymmetric encrypted
    let b:GPGEncrypted=1
    call s:GPGDebug(1, "this file is asymmetric encrypted")

    let b:GPGOptions+=["encrypt"]

    let start=match(output, "gpg: public key is [[:xdigit:]]\\{8}")
    while (start >= 0)
      let start=start + strlen("gpg: public key is ")
      let recipient=strpart(output, start, 8)
      call s:GPGDebug(1, "recipient is " . recipient)
      let name=s:GPGNameToID(recipient)
      if (strlen(name) > 0)
        let b:GPGRecipients+=[name]
        call s:GPGDebug(1, "name of recipient is " . name)
      else
        let b:GPGUnknownRecipients+=[recipient]
        echohl GPGWarning
        echom "The recipient " . recipient . " is not in your public keyring!"
        echohl None
      end
      let start=match(output, "gpg: public key is [[:xdigit:]]\\{8}", start)
    endwhile
  else
    " file is not encrypted
    let b:GPGEncrypted=0
    call s:GPGDebug(1, "this file is not encrypted")
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    set nobin
    return
  endif

  " check if the message is armored
  if (match(output, "gpg: armor header") >= 0)
    call s:GPGDebug(1, "this file is armored")
    let b:GPGOptions+=["armor"]
  endif

  " finally decrypt the buffer content
  " since even with the --quiet option passphrase typos will be reported,
  " we must redirect stderr (using shell temporarily)
  let &shellredir=s:shellredir
  let &shell=s:shell
  exec "'[,']!" . s:GPGCommand . " --quiet --decrypt " . s:stderrredirnull
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  if (v:shell_error) " message could not be decrypted
    silent u
    echohl GPGError
    let asd=input("Message could not be decrypted! (Press ENTER)")
    echohl None
    bwipeout
    set nobin
    return
  endif

  " turn off binary mode
  set nobin

  " call the autocommand for the file minus .gpg$
  execute ":doautocmd BufReadPost " . escape(expand("%:r"), ' *?\"'."'")
  call s:GPGDebug(2, "called autocommand for " . escape(expand("%:r"), ' *?\"'."'"))

  " refresh screen
  redraw!
endfunction

" Function: s:GPGEncrypt() {{{2
"
" encrypts the buffer to all previous recipients
"
function s:GPGEncrypt()
  " save window view
  let s:GPGWindowView = winsaveview()
  call s:GPGDebug(2, "saved window view " . string(s:GPGWindowView))

  " store encoding and switch to a safe one
  if &fileencoding != &encoding
    let s:GPGEncoding = &encoding
    let &encoding = &fileencoding
    call s:GPGDebug(2, "encoding was \"" . s:GPGEncoding . "\", switched to \"" . &encoding . "\"")
  else
    let s:GPGEncoding = ""
    call s:GPGDebug(2, "encoding and fileencoding are the same (\"" . &encoding . "\"), not switching")
  endif

  " switch buffer to binary mode
  set bin

  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  let options=""
  let recipients=""
  let field=0

  " built list of options
  if (!exists("b:GPGOptions") || len(b:GPGOptions) == 0)
    let b:GPGOptions=[]
    if (exists("g:GPGPreferSymmetric") && g:GPGPreferSymmetric == 1)
      let b:GPGOptions+=["symmetric"]
    else
      let b:GPGOptions+=["encrypt"]
    endif
    if (exists("g:GPGPreferArmor") && g:GPGPreferArmor == 1)
      let b:GPGOptions+=["armor"]
    endif
    call s:GPGDebug(1, "no options set, so using default options: " . string(b:GPGOptions))
  endif
  for option in b:GPGOptions
    let options=options . " --" . option . " "
  endfor

  let GPGUnknownRecipients=[]

  " Check recipientslist for unknown recipients again
  for cur_recipient in b:GPGRecipients
    " only do this if the line is not empty
    if (strlen(cur_recipient) > 0)
      let gpgid=s:GPGNameToID(cur_recipient)
      if (strlen(gpgid) <= 0)
        let GPGUnknownRecipients+=[cur_recipient]
        echohl GPGWarning
        echom "The recipient " . cur_recipient . " is not in your public keyring!"
        echohl None
      endif
    endif
  endfor

  " check if there are unknown recipients and warn
  if(len(GPGUnknownRecipients) > 0)
    echohl GPGWarning
    echom "There are unknown recipients!!"
    echom "Please use GPGEditRecipients to correct!!"
    echo
    echohl None
    call s:GPGDebug(1, "unknown recipients are: " . join(GPGUnknownRecipients, " "))

    " Remove unknown recipients from recipientslist
    let unknown_recipients=join(GPGUnknownRecipients, " ")
    let index=0
    while index < len(b:GPGRecipients)
      if match(unknown_recipients, b:GPGRecipients[index])
        echohl GPGWarning
        echom "Removing ". b:GPGRecipients[index] ." from recipientlist!\n"
        echohl None
        call remove(b:GPGRecipients, index)
      endif
    endwhile

    " Let user know whats happend and copy known_recipients back to buffer
    let dummy=input("Press ENTER to quit")
  endif

  " built list of recipients
  if (exists("b:GPGRecipients") && len(b:GPGRecipients) > 0)
    call s:GPGDebug(1, "recipients are: " . join(b:GPGRecipients, " "))
    for gpgid in b:GPGRecipients
      let recipients=recipients . " -r " . gpgid
    endfor
  else
    if (match(b:GPGOptions, "encrypt") >= 0)
      echohl GPGError
      echom "There are no recipients!!"
      echom "Please use GPGEditRecipients to correct!!"
      echo
      echohl None
    endif
  endif

  " encrypt the buffer
  let &shellredir=s:shellredir
  let &shell=s:shell
  silent exec "'[,']!" . s:GPGCommand . " --quiet --no-encrypt-to " . options . recipients . " " . s:stderrredirnull
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave
  call s:GPGDebug(1, "called gpg command is: " . "'[,']!" . s:GPGCommand . " --quiet --no-encrypt-to " . options . recipients . " " . s:stderrredirnull)
  if (v:shell_error) " message could not be encrypted
    silent u
    echohl GPGError
    let asd=input("Message could not be encrypted! File might be empty! (Press ENTER)")
    echohl None
    bwipeout
    return
  endif

endfunction

" Function: s:GPGEncryptPost() {{{2
"
" undo changes don by encrypt, after writing
"
function s:GPGEncryptPost()

  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    return
  endif

  " undo encryption of buffer content
  silent u

  " switch back from binary mode
  set nobin

  " restore encoding
  if s:GPGEncoding != ""
    let &encoding = s:GPGEncoding
    call s:GPGDebug(2, "restored encoding \"" . &encoding . "\"")
  endif

  " restore window view
  call winrestview(s:GPGWindowView)
  call s:GPGDebug(2, "restored window view" . string(s:GPGWindowView))

  " refresh screen
  redraw!
endfunction

" Function: s:GPGViewRecipients() {{{2
"
" echo the recipients
"
function s:GPGViewRecipients()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  if (exists("b:GPGRecipients"))
    echo 'This file has following recipients (Unknown recipients have a prepended "!"):'
    " echo the recipients
    for name in b:GPGRecipients
      let name=s:GPGIDToName(name)
      echo name
    endfor

    " put the unknown recipients in the scratch buffer
    echohl GPGWarning
    for name in b:GPGUnknownRecipients
      let name="!" . name
      echo name
    endfor
    echohl None

    " check if there is any known recipient
    if (len(b:GPGRecipients) == 0)
      echohl GPGError
      echom 'There are no known recipients!'
      echohl None
    endif
  endif
endfunction

" Function: s:GPGEditRecipients() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function s:GPGEditRecipients()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  " only do this if it isn't already a GPGRecipients_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername=bufname("%")
    let editbuffername="GPGRecipients_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      exe 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the recipients after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishRecipientsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        exe 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        exe 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

        " add a autocommand to regenerate the recipients after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishRecipientsBuffer()
      endif

      " empty the buffer
      silent normal! 1GdG
    endif

    " Mark the buffer as a scratch buffer
    setlocal buftype=acwrite
    setlocal bufhidden=hide
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:corresponding_to=buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: Please edit the list of recipients, one recipient per line'
    silent put ='GPG: Unknown recipients have a prepended \"!\"'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically'
    silent put ='GPG: Closing this buffer commits changes'
    silent put ='GPG: ----------------------------------------------------------------------'

    " put the recipients in the scratch buffer
    let recipients=getbufvar(b:corresponding_to, "GPGRecipients")

    for name in recipients
      let name=s:GPGIDToName(name)
      silent put =name
    endfor

    " put the unknown recipients in the scratch buffer
    let unknownRecipients=getbufvar(b:corresponding_to, "GPGUnknownRecipients")
    let syntaxPattern="\\(nonexistingwordinthisbuffer"
    for name in unknownRecipients
      let name="!" . name
      let syntaxPattern=syntaxPattern . "\\|" . name
      silent put =name
    endfor

    let syntaxPattern=syntaxPattern . "\\)"

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      exec('syntax match GPGUnknownRecipient    "' . syntaxPattern . '"')
      highlight clear GPGUnknownRecipient
      highlight link GPGUnknownRecipient  GPGHighlightUnknownRecipient

      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first recipient
    silent normal! G

  endif
endfunction

" Function: s:GPGFinishRecipientsBuffer() {{{2
"
" create a new recipient list from RecipientsBuffer
function s:GPGFinishRecipientsBuffer()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    exe 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endif

  " clear GPGRecipients and GPGUnknownRecipients
  let GPGRecipients=[]
  let GPGUnknownRecipients=[]

  " delete the autocommand
  autocmd! * <buffer>

  let currentline=1
  let recipient=getline(currentline)

  " get the recipients from the scratch buffer
  while (currentline <= line("$"))
    " delete all spaces at beginning and end of the line
    " also delete a '!' at the beginning of the line
    let recipient=substitute(recipient, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
    " delete comment lines
    let recipient=substitute(recipient, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(recipient) > 0)
      let gpgid=s:GPGNameToID(recipient)
      if (strlen(gpgid) > 0)
        if (match(GPGRecipients, gpgid) < 0)
          let GPGRecipients+=[gpgid]
        endif
      else
        if (match(GPGUnknownRecipients, recipient) < 0)
          let GPGUnknownRecipients+=[recipient]
          echohl GPGWarning
          echom "The recipient " . recipient . " is not in your public keyring!"
          echohl None
        endif
      end
    endif

    let currentline=currentline+1
    let recipient=getline(currentline)
  endwhile

  " write back the new recipient list to the corresponding buffer and mark it
  " as modified. Buffer is now for sure a encrypted buffer.
  call setbufvar(b:corresponding_to, "GPGRecipients", GPGRecipients)
  call setbufvar(b:corresponding_to, "GPGUnknownRecipients", GPGUnknownRecipients)
  call setbufvar(b:corresponding_to, "&mod", 1)
  call setbufvar(b:corresponding_to, "GPGEncrypted", 1)

  " check if there is any known recipient
  if (len(GPGRecipients) == 0)
    echohl GPGError
    echom 'There are no known recipients!'
    echohl None
  endif

  " reset modified flag
  set nomodified
endfunction

" Function: s:GPGViewOptions() {{{2
"
" echo the recipients
"
function s:GPGViewOptions()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  if (exists("b:GPGOptions"))
    echo 'This file has following options:'
    " echo the options
    for option in b:GPGOptions
      echo option
    endfor
  endif
endfunction

" Function: s:GPGEditOptions() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
function s:GPGEditOptions()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  " only do this if it isn't already a GPGOptions_* buffer
  if (match(bufname("%"), "^\\(GPGRecipients_\\|GPGOptions_\\)") != 0 && match(bufname("%"), "\.\\(gpg\\|asc\\|pgp\\)$") >= 0)

    " save buffer name
    let buffername=bufname("%")
    let editbuffername="GPGOptions_" . buffername

    " check if this buffer exists
    if (!bufexists(editbuffername))
      " create scratch buffer
      exe 'silent! split ' . escape(editbuffername, ' *?\"'."'")

      " add a autocommand to regenerate the options after a write
      autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishOptionsBuffer()
    else
      if (bufwinnr(editbuffername) >= 0)
        " switch to scratch buffer window
        exe 'silent! ' . bufwinnr(editbuffername) . "wincmd w"
      else
        " split scratch buffer window
        exe 'silent! sbuffer ' . escape(editbuffername, ' *?\"'."'")

        " add a autocommand to regenerate the options after a write
        autocmd BufHidden,BufUnload,BufWriteCmd <buffer> call s:GPGFinishOptionsBuffer()
      endif

      " empty the buffer
      silent normal! 1GdG
    endif

    " Mark the buffer as a scratch buffer
    setlocal buftype=nofile
    setlocal noswapfile
    setlocal nowrap
    setlocal nobuflisted
    setlocal nonumber

    " so we know for which other buffer this edit buffer is
    let b:corresponding_to=buffername

    " put some comments to the scratch buffer
    silent put ='GPG: ----------------------------------------------------------------------'
    silent put ='GPG: THERE IS NO CHECK OF THE ENTERED OPTIONS!'
    silent put ='GPG: YOU NEED TO KNOW WHAT YOU ARE DOING!'
    silent put ='GPG: IF IN DOUBT, QUICKLY EXIT USING :x OR :bd'
    silent put ='GPG: Please edit the list of options, one option per line'
    silent put ='GPG: Please refer to the gpg documentation for valid options'
    silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically'
    silent put ='GPG: Closing this buffer commits changes'
    silent put ='GPG: ----------------------------------------------------------------------'

    " put the options in the scratch buffer
    let options=getbufvar(b:corresponding_to, "GPGOptions")

    for option in options
      silent put =option
    endfor

    " delete the empty first line
    silent normal! 1Gdd

    " jump to the first option
    silent normal! G

    " define highlight
    if (has("syntax") && exists("g:syntax_on"))
      syntax match GPGComment "^GPG:.*$"
      highlight clear GPGComment
      highlight link GPGComment Comment
    endif
  endif
endfunction

" Function: s:GPGFinishOptionsBuffer() {{{2
"
" create a new option list from OptionsBuffer
function s:GPGFinishOptionsBuffer()
  " guard for unencrypted files
  if (exists("b:GPGEncrypted") && b:GPGEncrypted == 0)
    echohl GPGWarning
    echom "File is not encrypted, all GPG functions disabled!"
    echohl None
    return
  endif

  " go to buffer before doing work
  if (bufnr("%") != expand("<abuf>"))
    " switch to scratch buffer window
    exe 'silent! ' . bufwinnr(expand("<afile>")) . "wincmd w"
  endif

  " clear GPGOptions and GPGUnknownOptions
  let GPGOptions=[]
  let GPGUnknownOptions=[]

  " delete the autocommand
  autocmd! * <buffer>

  let currentline=1
  let option=getline(currentline)

  " get the options from the scratch buffer
  while (currentline <= line("$"))
    " delete all spaces at beginning and end of the line
    " also delete a '!' at the beginning of the line
    let option=substitute(option, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
    " delete comment lines
    let option=substitute(option, "^GPG:.*$", "", "")

    " only do this if the line is not empty
    if (strlen(option) > 0 && match(GPGOptions, option) < 0)
      let GPGOptions+=[option]
    endif

    let currentline=currentline+1
    let option=getline(currentline)
  endwhile

  " write back the new option list to the corresponding buffer and mark it
  " as modified
  call setbufvar(b:corresponding_to, "GPGOptions", GPGOptions)
  call setbufvar(b:corresponding_to, "&mod", 1)

  " reset modified flag
  set nomodified
endfunction

" Function: s:GPGNameToID(name) {{{2
"
" find GPG key ID corresponding to a name
" Returns: ID for the given name
function s:GPGNameToID(name)
  " ask gpg for the id for a name
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys \"" . a:name . "\"")
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  " when called with "--with-colons" gpg encodes its output _ALWAYS_ as UTF-8,
  " so convert it, if necessary
  if &encoding != "utf-8"
    let output=iconv(output, "utf-8", &encoding)
  endif
  let lines=split(output, "\n")

  " parse the output of gpg
  let pub_seen=0
  let uid_seen=0
  let counter=0
  let gpgids=[]
  let choices="The name \"" . a:name . "\" is ambiguous. Please select the correct key:\n"
  for line in lines
    let fields=split(line, ":")
    " search for the next uid
    if (pub_seen == 1)
      if (fields[0] == "uid")
        if (uid_seen == 0)
          let choices=choices . counter . ": " . fields[9] . "\n"
          let counter=counter+1
          let uid_seen=1
        else
          let choices=choices . "   " . fields[9] . "\n"
        endif
      else
        let uid_seen=0
        let pub_seen=0
      endif
    endif

    " search for the next pub
    if (pub_seen == 0)
      if (fields[0] == "pub")
        let gpgids+=[fields[4]]
        let pub_seen=1
      endif
    endif

  endfor

  " counter > 1 means we have more than one results
  let answer=0
  if (counter > 1)
    let choices=choices . "Enter number: "
    let answer=input(choices, "0")
    while (answer == "")
      let answer=input("Enter number: ", "0")
    endwhile
  endif

  return get(gpgids, answer, "")
endfunction

" Function: s:GPGIDToName(identity) {{{2
"
" find name corresponding to a GPG key ID
" Returns: Name for the given ID
function s:GPGIDToName(identity)
  " TODO is the encryption subkey really unique?

  " ask gpg for the id for a name
  let &shellredir=s:shellredir
  let &shell=s:shell
  let output=system(s:GPGCommand . " --quiet --with-colons --fixed-list-mode --list-keys " . a:identity )
  let &shellredir=s:shellredirsave
  let &shell=s:shellsave

  " when called with "--with-colons" gpg encodes its output _ALWAYS_ as UTF-8,
  " so convert it, if necessary
  if &encoding != "utf-8"
    let output=iconv(output, "utf-8", &encoding)
  endif
  let lines=split(output, "\n")

  " parse the output of gpg
  let pub_seen=0
  let uid=""
  for line in lines
    let fields=split(line, ":")
    if (pub_seen == 0) " search for the next pub
      if (fields[0] == "pub")
        let pub_seen=1
      endif
    else " search for the next uid
      if (fields[0] == "uid")
        let pub_seen=0
        let uid=fields[9]
        break
      endif
    endif
  endfor

  return uid
endfunction

" Function: s:GPGDebug(level, text) {{{2
"
" output debug message, if this message has high enough importance
function s:GPGDebug(level, text)
  if (g:GPGDebugLevel >= a:level)
    echom a:text
  endif
endfunction

" Section: Command definitions {{{1
command! GPGViewRecipients call s:GPGViewRecipients()
command! GPGEditRecipients call s:GPGEditRecipients()
command! GPGViewOptions call s:GPGViewOptions()
command! GPGEditOptions call s:GPGEditOptions()

" vim600: foldmethod=marker:foldlevel=0
