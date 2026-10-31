# Common noncollision scan path.
    16d4:	mov    r9d,DWORD PTR [r11+rsi*4]
    16d8:	cmp    ebp,esi
    16da:	setg   BYTE PTR [rsp+0x8]
    16df:	cmp    r12d,r9d
    16e2:	setne  BYTE PTR [rsp+0xc]
    16e7:	add    rsi,0x1
    16eb:	movzx  eax,BYTE PTR [rsp+0xc]
    16f0:	test   BYTE PTR [rsp+0x8],al
    16f4:	jne    16d4 <generate_keys+0x4f4>
