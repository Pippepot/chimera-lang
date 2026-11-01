  40124a:	49 63 c8             	movsxd rcx,r8d
  40124d:	44 8b 8c 8c 2c 0f 03 	mov    r9d,DWORD PTR [rsp+rcx*4+0x30f2c]
  401254:	00 
  401255:	41 83 c0 01          	add    r8d,0x1
  401259:	41 3b d9             	cmp    ebx,r9d
  40125c:	0f 85 0d 00 00 00    	jne    0x40126f
  401262:	b8 00 00 00 00       	mov    eax,0x0
  401267:	41 89 c1             	mov    r9d,eax
  40126a:	e9 11 00 00 00       	jmp    0x401280
  40126f:	45 3b c2             	cmp    r8d,r10d
  401272:	0f 8c d2 ff ff ff    	jl     0x40124a
