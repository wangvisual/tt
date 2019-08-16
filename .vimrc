" Tab
:set expandtab
:set tabstop=4
:set softtabstop=4
:set shiftwidth=4

" List tab & trailing spaces specially
" http://superuser.com/questions/921920/display-trailing-spaces-in-vim
:highlight SpecialKey term=bold cterm=underline,reverse
:set list
:set listchars+=tab:>-,trail:.,nbsp:¬

" Long lines
" http://vim.wikia.com/wiki/Highlight_long_lines
:au FileType perl,python,sh,text,c,vim let &l:colorcolumn=join(range(160,999),",")
:highlight clear ColorColumn
:highlight ColorColumn ctermfg=red
