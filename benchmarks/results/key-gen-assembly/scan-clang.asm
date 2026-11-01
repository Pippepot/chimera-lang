    13b0:	44 8b 44 b4 40       	mov    r8d,DWORD PTR [rsp+rsi*4+0x40]
    13b5:	49 89 d2             	mov    r10,rdx
    13b8:	0f 1f 84 00 00 00 00 	nop    DWORD PTR [rax+rax*1+0x0]
    13bf:	00 
    13c0:	46 8b 4c 94 40       	mov    r9d,DWORD PTR [rsp+r10*4+0x40]
    13c5:	45 39 c8             	cmp    r8d,r9d
    13c8:	74 08                	je     13d2 <main+0x262>
    13ca:	49 ff c2             	inc    r10
    13cd:	44 39 d7             	cmp    edi,r10d
    13d0:	7f ee                	jg     13c0 <main+0x250>
    13d2:	45 39 c8             	cmp    r8d,r9d
    13d5:	0f 84 85 fe ff ff    	je     1260 <main+0xf0>
    13db:	48 ff c6             	inc    rsi
    13de:	48 ff c2             	inc    rdx
    13e1:	48 39 c6             	cmp    rsi,rax
    13e4:	72 ca                	jb     13b0 <main+0x240>
    13e6:	e9 75 fe ff ff       	jmp    1260 <main+0xf0>
