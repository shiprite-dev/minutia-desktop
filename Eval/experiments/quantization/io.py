import sys,json,glob,os
for d in sorted(glob.glob(sys.argv[1]+"/*.mlmodelc")):
    m=json.load(open(d+"/metadata.json"))[0]
    print(os.path.basename(d))
    for k in("inputSchema","outputSchema"):
        print(" ",k[:3],[(x["name"],x["shape"],x.get("dataType")) for x in m[k]])
