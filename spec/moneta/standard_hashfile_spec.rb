describe 'standard_hashfile' do
  moneta_store :HashFile do
    {dir: File.join(tempdir, "simple_hashfile")}
  end

  moneta_specs STANDARD_SPECS
end
