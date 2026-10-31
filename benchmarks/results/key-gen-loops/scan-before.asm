# Common noncollision path with the right index below count.
  401b1f:	cmp    ebp,DWORD PTR [rsp+0x6c]
  401b23:	jl     0x401b3c
  401b3c:	mov    eax,ebp
  401b3e:	movsxd rcx,eax
  401b41:	mov    r8d,DWORD PTR [rsp+rcx*4+0x30f2c]
  401b49:	mov    eax,ebp
  401b4b:	add    eax,0x1
  401b4e:	mov    r9d,eax
  401b51:	cmp    r12d,r8d
  401b54:	je     0x401b62
  401b5a:	mov    ebp,r9d
  401b5d:	jmp    0x401b1f
