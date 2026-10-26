import importlib.util,json,pathlib,tempfile,urllib.request
root=pathlib.Path.cwd(); evidence=pathlib.Path('/home/bohn/.no-mistakes/evidence/01M5SBZKF04BPTHKEM4XDQWAA6')
spec=importlib.util.spec_from_file_location('native_fixture',root/'tests/opencode-v2-live-fixture.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
original=urllib.request.urlopen
with (evidence/'opencode-native-api.jsonl').open('w') as log:
 class RecordedResponse:
  def __init__(self,response,request): self.response=response; self.request=request
  def __enter__(self): self.response.__enter__(); return self
  def __exit__(self,*args): return self.response.__exit__(*args)
  def read(self,*args):
   data=self.response.read(*args)
   try: body=json.loads(data)
   except Exception: body=data.decode(errors='replace')
   log.write(json.dumps({'method':self.request.get_method(),'url':self.request.full_url,'response':body},ensure_ascii=False)+'\n'); log.flush(); return data
  def __getattr__(self,name): return getattr(self.response,name)
 def recording_open(request,*args,**kwargs): return RecordedResponse(original(request,*args,**kwargs),request)
 urllib.request.urlopen=recording_open
 with tempfile.TemporaryDirectory(prefix='native-api-',dir=evidence/'tmp') as lab:
  module.run(pathlib.Path(lab),str(root/'.test-tmp/opencode-tools/node_modules/@opencode/cli-linux-x64/bin/opencode'))
