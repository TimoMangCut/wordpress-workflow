 Workflow từ giờ:                                                                                                      
  # Máy khác clone lần đầu                                                                                            
  git clone https://github.com/TimoMangCut/wordpress-workflow.git                                                       
  cd wordpress-workflow                                                                                                 
  composer install          # rebuild tools/vendor/                                                                     
  pip install semgrep       # rebuild tmmc/ (nếu cần)                                                                   
                                                                                                                        
  # Sync thường xuyên                                                                                                   
  git pull                                                                                                              
                                                                                                                        
  # Sau khi hoàn thành mỗi session — tôi sẽ push trước khi bắt đầu session tiếp                                         
  git push
