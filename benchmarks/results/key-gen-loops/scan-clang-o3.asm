# Common noncollision scan path.
    13c0:	mov    r9d,DWORD PTR [rsp+r10*4+0x40]
    13c5:	cmp    r8d,r9d
    13c8:	je     13d2 <main+0x262>
    13ca:	inc    r10
    13cd:	cmp    edi,r10d
    13d0:	jg     13c0 <main+0x250>
