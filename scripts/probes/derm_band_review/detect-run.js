async (page) => {
  const PAGES = [{"k":"ticket-309661#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1604/address_1.jpeg","top":29.3,"bot":65.8},{"k":"ticket-309661#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1604/address_2.jpeg","top":28.7,"bot":66.4},{"k":"ticket-309898#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1630/address_1.jpeg","top":24.37,"bot":67.39},{"k":"ticket-309944#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1635/address_1.jpeg","top":26.028,"bot":67.1},{"k":"ticket-310429#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1646/address_1.jpeg","top":25.8,"bot":64.4},{"k":"ticket-310429#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1646/address_2.jpeg","top":25.8,"bot":63.7},{"k":"ticket-310590#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1671/address_1.JPG","top":25.318,"bot":63.273},{"k":"ticket-310590#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1671/address_2.JPG","top":25.517,"bot":63.326},{"k":"ticket-310607#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1667/address_1.jpg","top":23.7,"bot":63.6},{"k":"ticket-311780#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1725/address_1.jpg","top":25.887,"bot":63.468},{"k":"ticket-311780#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1725/address_2.jpg","top":25.649,"bot":63.555},{"k":"ticket-820714#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1622/address_1.jpeg","top":27.55,"bot":60.84},{"k":"ticket-828604#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1246/address_1.JPG","top":null,"bot":null},{"k":"ticket-829788#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1351/address_1.jpeg","top":26,"bot":63},{"k":"ticket-830088#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1362/address_1.png","top":25.5,"bot":62},{"k":"ticket-830310#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1370/address_1.JPG","top":26.5,"bot":65.5},{"k":"ticket-830413#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1368/address_1.JPG","top":25.5,"bot":62.5},{"k":"ticket-830574#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1453/address_1.JPG","top":28.037,"bot":64.96},{"k":"ticket-830673#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1625/address_1.JPG","top":25.57,"bot":66.56},{"k":"ticket-830714#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1622/address_1.jpeg","top":null,"bot":null},{"k":"ticket-831047#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1638/address_1.jpg","top":24,"bot":60.9},{"k":"ticket-831220#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1665/address_1.png","top":23.9,"bot":64.3},{"k":"ticket-831710#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1679/address_1.JPG","top":25.9,"bot":64.2},{"k":"ticket-831938#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1680/address_1.JPG","top":25.205,"bot":64.4},{"k":"ticket-831938#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1680/address_2.JPG","top":25.351,"bot":64.4},{"k":"ticket-832194#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1691/address_1.JPG","top":24.4,"bot":64.7},{"k":"ticket-832194#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1691/address_2.JPG","top":23.9,"bot":63.5},{"k":"ticket-832487#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1700/address_1.jpg","top":24.355,"bot":63.468},{"k":"ticket-832487#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1700/address_2.jpg","top":23.871,"bot":63.065},{"k":"ticket-832996#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1720/address_1.jpg","top":24.517,"bot":66.782},{"k":"backfill-829201#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1276/address_1.JPG","top":25.5,"bot":64.7},{"k":"backfill-829201#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1276/address_2.JPG","top":24.5,"bot":63.9},{"k":"derm/1158#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1158/address_1.jpg","top":28,"bot":60.1},{"k":"derm/1171#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1171/address_1.JPG","top":27.4,"bot":60.8},{"k":"derm/1173#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1173/address_1.JPG","top":27.8,"bot":61.6},{"k":"derm/1187#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1187/address_1.jpg","top":23.6,"bot":58.8},{"k":"derm/1192#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1192/address_1.JPG","top":27.6,"bot":60.9},{"k":"derm/1194#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1194/address_2.jpeg","top":25.56,"bot":63.28},{"k":"derm/1194#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1203/address_2_1782851826904-2nntq3.jpeg","top":25.19,"bot":63.35},{"k":"derm/1194#3","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1203/address_3_1782851827632-15orzg.jpeg","top":25.5,"bot":63.6},{"k":"derm/1208#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1208/address_1.jpg","top":27.1,"bot":61.4},{"k":"derm/1208#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1208/address_2.jpg","top":27,"bot":60.4},{"k":"derm/1218#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1218/address_1.JPG","top":28.5,"bot":63.1},{"k":"derm/1218#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1218/address_2.JPG","top":29,"bot":63.5},{"k":"derm/1218#3","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1218/address_3.JPG","top":26.2,"bot":66.4},{"k":"derm/1218#4","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1228/address_4_1783111552481-f224ja.jpg","top":25.33,"bot":63.67},{"k":"derm/1236#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1236/address_1_1782329744899.JPG","top":28.8,"bot":63.4},{"k":"derm/1241#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1241/address_1.JPG","top":29.4,"bot":63.6},{"k":"derm/1246#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1246/address_1.JPG","top":27.5,"bot":60.9},{"k":"derm/1252#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1252/address_1.JPG","top":27.8,"bot":61.5},{"k":"ticket-296623#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/512/address_p2.jpg","top":28,"bot":60.8},{"k":"ticket-306915#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1354/address_1.png","top":25.5,"bot":62},{"k":"ticket-306915#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1354/address_2.png","top":25,"bot":63},{"k":"ticket-308684#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1336/address_1.JPG","top":22.9,"bot":66.4},{"k":"ticket-308684#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1336/address_2.JPG","top":20.4,"bot":61.9},{"k":"ticket-308792#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1343/address_1.JPG","top":29,"bot":61.1},{"k":"ticket-308792#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1343/address_2.JPG","top":28.7,"bot":61.7},{"k":"ticket-826114#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1297/address_1.JPG","top":27.8,"bot":61.2},{"k":"ticket-826114#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1297/address_2.JPG","top":28.6,"bot":62},{"k":"ticket-829216#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1299/address_2.JPG","top":28.3,"bot":61.5},{"k":"ticket-829216#3","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1299/address_3.JPG","top":28.5,"bot":61.8},{"k":"ticket-829216#4","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1299/address_4.JPG","top":27.4,"bot":60.8},{"k":"ticket-829322#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1328/address_1.JPG","top":25.1,"bot":63.9},{"k":"ticket-829322#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1328/address_2.JPG","top":24.73,"bot":64.34},{"k":"window10-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/196/address.jpg","top":29.5,"bot":64.6},{"k":"window10-sheet10#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/902/address.jpg","top":29.2,"bot":61.8},{"k":"window10-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/311/address.jpg","top":31.9,"bot":68.2},{"k":"window10-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/745/address.jpg","top":26.9,"bot":60.1},{"k":"window10-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/465/address.jpg","top":27.9,"bot":60.5},{"k":"window10-sheet4#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/284/address.jpg","top":26.96,"bot":59.65},{"k":"window10-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/492/address.jpg","top":28.4,"bot":61.5},{"k":"window10-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/142/address.jpg","top":28.2,"bot":61.3},{"k":"window10-sheet8#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/157/address.jpg","top":27.8,"bot":60.6},{"k":"window10-sheet9#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/557/address.jpg","top":27.8,"bot":60.5},{"k":"window11-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/754/address.jpg","top":27.7,"bot":60.6},{"k":"window11-sheet10#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/840/address.jpg","top":27.8,"bot":60.4},{"k":"window11-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/315/address.jpg","top":27.6,"bot":60.4},{"k":"window11-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/181/address.jpg","top":27.6,"bot":60.3},{"k":"window11-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/488/address.jpg","top":27.7,"bot":60.2},{"k":"window11-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/432/address.jpg","top":27.3,"bot":60.1},{"k":"window11-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/14/address.jpg","top":27.7,"bot":60.6},{"k":"window11-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/445/address.jpg","top":28,"bot":60.9},{"k":"window11-sheet8#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/77/address.jpg","top":28.6,"bot":61.4},{"k":"window11-sheet9#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/222/address.jpg","top":27.5,"bot":60.4},{"k":"window12-sheet10#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/282/address.jpg","top":28,"bot":62.3},{"k":"window12-sheet11#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/230/address.jpg","top":28.2,"bot":61.4},{"k":"window12-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/957/address.jpg","top":27.6,"bot":61},{"k":"window12-sheet2#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/957/address_p2.jpg","top":28.5,"bot":62.6},{"k":"window12-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/337/address.jpg","top":26.9,"bot":61.2},{"k":"window12-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/161/address.jpg","top":27,"bot":61.7},{"k":"window12-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/87/address.jpg","top":28.2,"bot":61.1},{"k":"window12-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/353/address.jpg","top":28.8,"bot":64.3},{"k":"window12-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/920/address.jpg","top":27.3,"bot":60.4},{"k":"window12-sheet8#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/601/address.jpg","top":25.3,"bot":59.7},{"k":"window12-sheet9#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/890/address.jpg","top":27.3,"bot":60.5},{"k":"window13-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/854/address.jpg","top":27.9,"bot":60.9},{"k":"window13-sheet1#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/898/address.jpg","top":27.4,"bot":60},{"k":"window13-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/194/address.jpg","top":27.2,"bot":60.7},{"k":"window13-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/782/address.jpg","top":29.5,"bot":65.4},{"k":"window13-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/29/address.jpg","top":27.7,"bot":60.8},{"k":"window13-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/776/address.jpg","top":29.1,"bot":62.7},{"k":"window13-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/816/address.jpg","top":28.6,"bot":61.9},{"k":"window13-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/926/address.jpg","top":27.5,"bot":60.4},{"k":"window3-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1074/address.jpg","top":27.8,"bot":60.2},{"k":"window3-sheet3#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1074/address_p2.jpg","top":28.6,"bot":62.7},{"k":"window3-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1062/address.jpg","top":25.6,"bot":61.7},{"k":"window3-sheet4#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1062/address_p2.jpg","top":28,"bot":61.3},{"k":"window3-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1057/address.jpg","top":28.3,"bot":62},{"k":"window3-sheet5#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1057/address_p2.jpg","top":28.8,"bot":62.3},{"k":"window3-sheet5#3","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1057/address_p3.jpg","top":28.9,"bot":62.5},{"k":"window4-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1041/address.jpg","top":28.1,"bot":62.2},{"k":"window4-sheet1#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1041/address_p2.jpg","top":28,"bot":61.3},{"k":"window4-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/984/address.jpg","top":28.2,"bot":62.1},{"k":"window4-sheet2#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/984/address_p2.jpg","top":28.3,"bot":61.8},{"k":"window4-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/251/address.jpg","top":27.3,"bot":59.9},{"k":"window4-sheet3#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/251/address_p2.jpg","top":27.5,"bot":60.2},{"k":"window4-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1043/address.jpg","top":28.1,"bot":61.2},{"k":"window4-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/970/address.jpg","top":28,"bot":61.5},{"k":"window4-sheet5#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/970/address_p2.jpg","top":29,"bot":62.2},{"k":"window4-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/976/address.jpg","top":28.1,"bot":60.7},{"k":"window5-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/960/address.jpg","top":20.9,"bot":57.3},{"k":"window5-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/671/address.jpg","top":27.6,"bot":61.4},{"k":"window5-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/52/address.jpg","top":null,"bot":null},{"k":"window5-sheet3#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/52/address_p2.jpg","top":28.4,"bot":65.6},{"k":"window5-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/295/address.jpg","top":27.8,"bot":61.6},{"k":"window5-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/933/address.jpg","top":27,"bot":59.7},{"k":"window5-sheet5#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/933/address_p2.jpg","top":28.3,"bot":62.3},{"k":"window5-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/121/address.jpg","top":24.5,"bot":60.4},{"k":"window5-sheet6#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/121/address_p2.jpg","top":28,"bot":61.9},{"k":"window5-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/842/address.jpg","top":27.7,"bot":60.9},{"k":"window6-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/417/address.jpg","top":28.4,"bot":61.7},{"k":"window6-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/227/address.jpg","top":27.1,"bot":60.3},{"k":"window6-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/725/address.jpg","top":28.6,"bot":62.2},{"k":"window6-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/13/address.jpg","top":27.6,"bot":60.6},{"k":"window6-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/364/address.jpg","top":28.2,"bot":61.7},{"k":"window6-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/174/address.jpg","top":25.1,"bot":58.7},{"k":"window6-sheet7#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/138/address.jpg","top":27.7,"bot":60.6},{"k":"window6-sheet8#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/590/address.jpg","top":27,"bot":60.2},{"k":"window6-sheet8#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/590/address_p2.jpg","top":27.1,"bot":60.6},{"k":"window7-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/661/address.jpg","top":27.6,"bot":60.5},{"k":"window7-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/23/address.jpg","top":28,"bot":60.9},{"k":"window7-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/869/address.jpg","top":27.3,"bot":58.9},{"k":"window7-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/638/address.jpg","top":27.5,"bot":61.1},{"k":"window7-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/206/address.jpg","top":27.3,"bot":61.1},{"k":"window7-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/630/address.jpg","top":27.7,"bot":61.3},{"k":"window8-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/763/address.jpg","top":27.4,"bot":61.9},{"k":"window8-sheet1#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/763/address_p2.jpg","top":27.6,"bot":61.1},{"k":"window8-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/626/address.jpg","top":28.6,"bot":63},{"k":"window8-sheet2#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/626/address_p2.jpg","top":27.3,"bot":60.5},{"k":"window8-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/279/address.jpg","top":27.9,"bot":60.1},{"k":"window8-sheet3#2","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/78/address.jpg","top":29.5,"bot":62.8},{"k":"window8-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/351/address.jpg","top":27.7,"bot":61},{"k":"window8-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/439/address.jpg","top":28.4,"bot":63.3},{"k":"window8-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/435/address.jpg","top":28.9,"bot":63.3},{"k":"window9-sheet1#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/153/address.jpg","top":27.2,"bot":60.1},{"k":"window9-sheet2#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/184/address.jpg","top":27.4,"bot":60.3},{"k":"window9-sheet3#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/106/address.jpg","top":27.8,"bot":60.4},{"k":"window9-sheet4#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/611/address.jpg","top":29.1,"bot":64},{"k":"window9-sheet5#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/269/address.jpg","top":27.2,"bot":60.3},{"k":"window9-sheet6#1","src":"https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/382/address.jpg","top":27.9,"bot":60.5}];
  // goto rather than setContent: setContent waits for "load" and has timed out on this MCP page
  // after a previous run left a download pending.
  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  const out = await page.evaluate(async (PAGES) => {

    const FULL_RUN   = 0.80;   // at or above this the rule spans the whole form: a SLOT BOUNDARY
    const MIN_RUN    = 0.33;   // below this it is not a printed rule at all
    const MIN_SEP_PP = 0.70;   // two rules closer than this are one rule seen twice
    const SLOPES     = [-8,-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6,8].map(v => v / 1000);

    const load = src => new Promise((ok, no) => {
      const i = new Image(); i.crossOrigin = 'anonymous';
      i.onload = () => ok(i); i.onerror = () => no(new Error('load fail')); i.src = src;
    });

    const results = [];
    for (const P of PAGES) {
      const rec = { k: P.k, top: P.top, bot: P.bot };
      try {
        const img = await load(P.src);
        const W = img.naturalWidth, H = img.naturalHeight;
        const c = document.createElement('canvas'); c.width = W; c.height = H;
        const g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        const d = g.getImageData(0, 0, W, H).data;

        const L = new Uint8Array(W * H);
        for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
          const i = (y * W + x) * 4;
          L[y * W + x] = (0.299 * d[i] + 0.587 * d[i+1] + 0.114 * d[i+2]) | 0;
        }

        // The roster band. The extent when the page has one, else a generous default. Measuring
        // the paper level over the WHOLE page would drag in the dark form header at the top.
        const yA = Math.max(2, Math.round(((P.top != null ? P.top : 18) - 5) / 100 * H));
        const yB = Math.min(H - 3, Math.round(((P.bot != null ? P.bot : 72) + 5) / 100 * H));
        const x0 = Math.floor(W * 0.02), x1 = Math.floor(W * 0.92), span = x1 - x0;
        const xMid = (x0 + x1) / 2;

        rec.W = W; rec.H = H;
        {
          const s = [];
          for (let y = yA; y <= yB; y += 3) for (let x = x0; x < x1; x += 5) s.push(L[y * W + x]);
          s.sort((a, b) => a - b);
          rec.luma_p10 = s[(s.length * 0.10) | 0];
          rec.luma_med = s[(s.length * 0.50) | 0];
          rec.luma_p90 = s[(s.length * 0.90) | 0];
        }

        // Per-column paper level: the 70th percentile of that column's luma down the roster. A
        // column that happens to carry a vertical table line is still mostly paper, so a high
        // percentile finds the paper rather than the line.
        const paper = new Float32Array(W);
        const cut = new Float32Array(W);
        {
          const col = [];
          for (let x = x0; x < x1; x++) {
            col.length = 0;
            for (let y = yA; y <= yB; y += 2) col.push(L[y * W + x]);
            col.sort((a, b) => a - b);
            const p = col[(col.length * 0.70) | 0];
            paper[x] = p;
            cut[x] = p - Math.max(9, p * 0.10);
          }
        }

        // runFrac under a given shear. dy(x) = round(slope * (x - xMid)), so slope is rise over
        // run across the page: 0.004 is about 0.23 degrees, roughly 4px across a 1000px sheet.
        const profileFor = (slope) => {
          const rf = new Float32Array(H);
          for (let y = yA - 12; y <= yB + 12; y++) {
            if (y < 1 || y >= H - 1) continue;
            let best = 0, cur = 0;
            for (let x = x0; x < x1; x++) {
              const yy = y + ((slope * (x - xMid)) | 0);
              if (yy < 1 || yy >= H - 1) { cur = 0; continue; }
              const t = cut[x];
              const dark = L[yy * W + x] < t || L[(yy - 1) * W + x] < t || L[(yy + 1) * W + x] < t;
              if (dark) { cur++; if (cur > best) best = cur; } else cur = 0;
            }
            rf[y] = best / span;
          }
          return rf;
        };

        // Pick the shear that maximises full-width evidence. Score = number of rows reaching
        // FULL_RUN, tie-broken toward slope 0 so a page with no skew is left alone.
        let bestSlope = 0, bestScore = -1, zeroScore = 0;
        for (const s of SLOPES) {
          const rf = profileFor(s);
          let n = 0;
          for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= FULL_RUN) n++;
          if (s === 0) zeroScore = n;
          if (n > bestScore || (n === bestScore && Math.abs(s) < Math.abs(bestSlope))) { bestScore = n; bestSlope = s; }
        }
        rec.skew = bestSlope;
        rec.skew_rows_at_zero = zeroScore;
        rec.skew_rows_best = bestScore;
        rec.skew_gain = bestScore - zeroScore;

        const rf = profileFor(bestSlope);

        // ink fraction at the chosen shear, recorded for continuity with the 2026-08-03 detector
        const inkAt = (y) => {
          let n = 0;
          for (let x = x0; x < x1; x++) {
            const yy = y + ((bestSlope * (x - xMid)) | 0);
            if (yy >= 0 && yy < H && L[yy * W + x] < cut[x]) n++;
          }
          return n / span;
        };

        // Non-maximum suppression. Greedily take the strongest remaining row, then forbid
        // everything within MIN_SEP. No thickness filter: v1 discarded thick groups and thereby
        // deleted exactly the strongest rules whenever their shoulders merged with nearby ink.
        const sep = Math.max(3, Math.round(H * MIN_SEP_PP / 100));
        const cand = [];
        for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= MIN_RUN) cand.push(y);
        cand.sort((a, b) => rf[b] - rf[a]);
        const taken = [];
        for (const y of cand) {
          if (taken.some(t => Math.abs(t - y) < sep)) continue;
          taken.push(y);
        }

        const rules = taken.map(y => {
          // refine to the centroid of the plateau, which removes the upward bias the one-row
          // vertical tolerance gives to a plain argmax
          // ⚠ CAP THE PLATEAU. Unbounded expansion walks across a flat stretch of profile and
          // drags the centroid off the peak: it collapsed a boundary at run 0.997 and a divider at
          // 0.427 onto the same position on ticket-832487 p1, which is both a lost rule and a
          // primary-key collision. The cap is half the NMS separation, so a refined position can
          // never cross into a neighbouring peak's territory.
          const v = rf[y];
          const lim = Math.max(2, Math.round(H * MIN_SEP_PP / 200));
          let a = y, b = y;
          while (a > 1 && y - a < lim && rf[a - 1] >= v - 0.03) a--;
          while (b < H - 2 && b - y < lim && rf[b + 1] >= v - 0.03) b++;
          const mid = (a + b) / 2;
          return {
            pct: +(((mid + 0.5) / H) * 100).toFixed(3),
            run: +v.toFixed(3),
            ink: +inkAt(y).toFixed(3),
            kind: v >= FULL_RUN ? 'full' : 'part',
            thick: b - a + 1,
          };
        }).sort((p, q) => p.pct - q.pct);

        rec.rules = rules;
        const full = rules.filter(r => r.kind === 'full').map(r => r.pct);
        rec.n_full = full.length;
        rec.n_part = rules.length - full.length;

        // gaps between consecutive full-width rules, for the confidence gate: a MISSING rule shows
        // up as one gap that is a clean multiple of the others
        const gaps = [];
        for (let i = 1; i < full.length; i++) gaps.push(+(full[i] - full[i - 1]).toFixed(3));
        rec.gaps = gaps;
        const sorted = [...gaps].sort((a, b) => a - b);
        rec.pitch = sorted.length ? sorted[(sorted.length / 2) | 0] : null;
        rec.max_gap = gaps.length ? Math.max(...gaps) : null;
        rec.min_gap = gaps.length ? Math.min(...gaps) : null;
      } catch (e) { rec.error = String(e).slice(0, 90); }
      results.push(rec);
    }
    return results;
  }, PAGES);

  await page.goto('about:blank', { waitUntil: 'domcontentloaded' });
  await page.evaluate(() => {
    const a = document.createElement('a'); a.id = 'dl'; a.textContent = 'x';
    document.body.appendChild(a);
  });
  const payload = JSON.stringify(out);
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 120000 }),
    page.evaluate((txt) => {
      const a = document.getElementById('dl');
      a.href = URL.createObjectURL(new Blob([txt], { type: 'application/json' }));
      a.download = 'detect.json';
      a.click();
    }, payload),
  ]);
  await download.saveAs('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/scripts/probes/tmp/det-fleet.json');
  const bad = out.filter(r => r.error).map(r => r.k + ':' + r.error);
  return out.length + ' pages -> C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/scripts/probes/tmp/det-fleet.json (' + payload.length + ' bytes)'
    + (bad.length ? '  ERRORS: ' + bad.join(' | ') : '');
}