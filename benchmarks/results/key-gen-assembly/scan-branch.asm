
branch:     file format binary


Disassembly of section .data:

0000000000401221 <.data+0x1221>:
  401221:	44 89 c0             	mov    eax,r8d
  401224:	83 c0 01             	add    eax,0x1
  401227:	89 c5                	mov    ebp,eax
  401229:	49 63 c8             	movsxd rcx,r8d
  40122c:	8b 9c 8c 2c 0f 03 00 	mov    ebx,DWORD PTR [rsp+rcx*4+0x30f2c]
  401233:	41 83 f9 01          	cmp    r9d,0x1
  401237:	0f 84 05 00 00 00    	je     0x401242
  40123d:	e9 3e 00 00 00       	jmp    0x401280
  401242:	44 8b c5             	mov    r8d,ebp
  401245:	e9 18 00 00 00       	jmp    0x401262
  40124a:	49 63 c8             	movsxd rcx,r8d
  40124d:	44 8b 8c 8c 2c 0f 03 	mov    r9d,DWORD PTR [rsp+rcx*4+0x30f2c]
  401254:	00 
  401255:	41 83 c0 01          	add    r8d,0x1
  401259:	41 3b d9             	cmp    ebx,r9d
  40125c:	0f 84 16 00 00 00    	je     0x401278
  401262:	45 3b c2             	cmp    r8d,r10d
  401265:	0f 8c df ff ff ff    	jl     0x40124a
  40126b:	b8 01 00 00 00       	mov    eax,0x1
  401270:	41 89 c1             	mov    r9d,eax
  401273:	e9 08 00 00 00       	jmp    0x401280
  401278:	b8 00 00 00 00       	mov    eax,0x0
  40127d:	41 89 c1             	mov    r9d,eax
  401280:	44 8b c5             	mov    r8d,ebp
  401283:	e9 78 ff ff ff       	jmp    0x401200
  401288:	41 83 f9 01          	cmp    r9d,0x1
  40128c:	0f 85 13 00 00 00    	jne    0x4012a5
  401292:	8b 44 24 58          	mov    eax,DWORD PTR [rsp+0x58]
  401296:	41 89 c0             	mov    r8d,eax
