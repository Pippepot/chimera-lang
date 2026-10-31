# Common noncollision path with the right index below count.
  401259:	mov    eax,r8d
  40125c:	movsxd rcx,eax
  40125f:	mov    r9d,DWORD PTR [rsp+rcx*4+0x30f2c]
  401267:	add    r8d,0x1
  40126b:	cmp    ebx,r9d
  40126e:	jne    0x401281
  401281:	cmp    r8d,r10d
  401284:	jl     0x401259
