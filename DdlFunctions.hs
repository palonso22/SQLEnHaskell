module DdlFunctions where
import System.Environment
import Prelude hiding (catch,lookup)
import System.Directory
import Control.Exception
import System.IO.Error hiding (catch)
import AST (BaseName,CArgs (..),TableInfo(..),Type,Env(..),TableDescript(..),Args,UserInfo(..),TableName,
            Reference,ForeignKey,Tab,fields0,fields,fields2,fields3,createInfoRegister,
            createInfoRegister2,RefOption(..),printTable,show3,Query,TabsUserInfo,emptyHM,runState,unWrapperQuery)
import DynGhc (compile)
import Data.HashMap.Strict (fromList,HashMap,(!),update,lookup,alter,union,adjust,empty)
import Error (errorCreateTableKeyOrFK,tableExists,errorDropTable,succesDropTable,
              errorCreateReference,succesCreateTable,succesCreateReference,
              errorCheckReference,put,imposibleDelete,errorCreateTableNulls, tableDoesntExist,syspath,
              baseExist,baseNotExist,tablepath,errorDropAllTable,succesDropAllTables)
import Url
import Avl ((|||),toTree,deleteT,comp,comp2,comp3,write,isMember,AVL,value,filterT,search,push)
import DynGhc (appendLine,reWrite)
import Data.List (elem)
import DynGhc (obtainTable,loadInfoTable)
import Data.Maybe (isNothing,fromJust,isJust)
import COrdering  (COrdering (..),fstByCC)
import Check (checkReference, checkNullifies)
import qualified Data.Set as Set (fromList,isSubsetOf)
import Control.DeepSeq

-- Modulo de funciones ddl

code :: String -> TableDescript -> String
code f (_,_,_,k,_) =   "module " ++ f ++ " where \n" ++
                       "import AST (Args (..),Type(..),TableInfo(..),Dates(..),Times(..),DateTime(..))\n" ++
                       "import Data.Typeable\n" ++
                       "import Data.HashMap.Strict hiding (keys) \n" ++
                       "import Avl (AVL(..),m)\n" ++
                       "import COrdering\n" ++
                       "keys = " ++ (show k) ++ "\n" ++
                       "upd0 = E"



deleteFile :: FilePath -> IO ()
deleteFile p = removeFile p `catch` handleExists
  where handleExists e
          | isDoesNotExistError e = error "Error fatal"
          | otherwise = throwIO e


deleteDirectory :: FilePath -> IO ()
deleteDirectory p = removeDirectoryRecursive p `catch` handleExists
  where handleExists e
           | isDoesNotExistError e = error "Error fatal"
           | otherwise = throwIO e




createDataBase :: BaseName -> Env -> IO ()
createDataBase b e = case name e of
                        "" -> put "Primero logueate"
                        n -> do let c = (e,emptyHM,emptyHM)
                                let query =  obtainTable syspath "Users" :: Query TabsUserInfo
                                res <- (runState query) c
                                case res of
                                   Left msgError -> put msgError
                                   Right (_,t) -> let r = fromList [("userName",UN n)]
                                                  in  case search ["userName"] r t of
                                                       Nothing -> put "Error fatal"
                                                       Just reg -> let (UB bases) = reg ! "dataBases"
                                                                   -- Si ya existe la base devolver un error
                                                                   in if elem b bases then baseExist b
                                                                   -- Sino agregar
                                                                      else let reg' = adjust (\_ -> UB $ b:bases) "dataBases" reg
                                                                    -- Reemplazar info vieja con info nueva
                                                                               t' = push (fun reg') reg' t
                                                                           in do reWrite t' (syspath ++ "/Users")
                                                                                 createDirectory $ url $  e {dataBase=b}






dropDataBase :: BaseName -> Env -> IO ()
dropDataBase b e = case name e of
                      "" -> put "No estás logueado"
                      n -> do res <- unWrapperQuery e $ obtainTable syspath "Users"
                              case res of
                               Left msgError -> put msgError
                               Right t -> let r = fromList [("userName",UN n)]
                                          in  case search ["userName"] r t of
                                                   Nothing -> put "Error fatal2"
                                                   Just reg ->
                                                      let (UB bases) = reg ! "dataBases"
                                                               -- Si no existe la base devolver un error
                                                      in if not $ elem b bases then put $ baseNotExist b
                                                         else let reg' = adjust (\_ -> UB $ [x | x <- bases, x /= b]) "dataBases" reg
                                                                    -- Reemplazar info vieja con info nueva
                                                                  t' = push (fun reg') reg' t
                                                              in do reWrite t' (syspath ++ "/Users")
                                                                    res2 <- unWrapperQuery e $ obtainTable syspath "Tables"
                                                                    case res2 of
                                                                     Left msgError -> put msgError
                                                                     Right t2 -> do let t2' = filterT fun2 t2
                                                                                    reWrite t2' (syspath ++ "/Tables")
                                                                                    deleteDirectory $ url $ e {dataBase = b}

 where fun2 x = let (TB b') = x ! "dataBase"
                in b /= b'


fun reg x = fstByCC (\z1 z2 -> comp2 ["userName"] z1 z2 ) reg x



createTable :: Env -> TableName -> [CArgs]  -> IO ()
createTable e n c =
 do res <- unWrapperQuery e $ obtainTable syspath "Tables"
    case res of
      Left msgError -> putStrLn msgError
      Right t -> do let reg = createInfoRegister2 e n
                    -- Ya existe la tabla?
                    if isMember fields reg t then tableExists n
                    else do let (q@(scheme,types,nulls,k,fk),r) = collect c ||| url' e n
                            let (setNulls,setScheme) = toSet nulls ||| toSet scheme
                            let (setKey,setFKFields) = toSet k ||| toSet [x | (_,xs,_,_) <- fk,(x,_) <- xs]
                            let setFKNulls = toSet [x | (_,xs,s1,s2) <- fk,(x,_) <- xs,s1 == Nullifies || s2 == Nullifies ]
                           -- La clave no puede ser nula
                           -- La clave y la clave foránea son parte del esquema?
                            if  setKey `isSubset` setNulls || (not $ setFKNulls `isSubset` setNulls) then errorCreateTableNulls
                            else -- Tiene que haber una clave
                                -- La clave tiene que ser parte del esquema
                                -- Las claves foraneas tienen que ser parte del esquema
                               if k == [] || (not $ setKey `isSubset` setScheme) ||  (not $ setFKFields `isSubset`  setScheme) then errorCreateTableKeyOrFK
                               else --- Las referencias deben ser correctas
                                      do res <- unWrapperQuery e $ checkReference e fk (fromList $ zip scheme types)
                                         case res of
                                           Left errorMsg -> put errorMsg
                                           Right b -> if not b  then errorCheckReference
                                                      else do d1 <- createReference n e fk
                                                              let hs = r ++ ".hs"
                                                              d2 <- d1 `deepseq` writeFile hs $ code n q
                                                              d2 `deepseq` compile hs
                                                              removeFile $ r ++ ".hi"
                                                              let t' = tree reg [TS scheme,TT types,TK k,TFK [] , TR (splitFK fk),HN nulls]
                                                              d3 <- appendLine tablepath t'
                                                              d3 `deepseq` succesCreateTable n





  where tree reg l = toTree [union reg (fromList $ zip (drop 3 fields2) l)]
        splitFK f = [(x,xs) | (x,xs,_,_) <- f]
        isSubset = Set.isSubsetOf
        toSet = Set.fromList






-- Crear referencias
createReference :: TableName -> Env -> [ForeignKey] -> IO ()
createReference _ _ [] = return ()
createReference n e ((x,xs,o1,o2):ys) =
  do res <- unWrapperQuery e $ obtainTable syspath "Tables"
     case res of
      Left msgError -> put msgError
      Right t ->  do let reg = createInfoRegister2 e  x
                     -- Reemplaza en el árbol t el registro correspondiente
                     let t' = write  (fun (n,xs,o1,o2) fields reg) t
                     reWrite t' tablepath
                     succesCreateReference n x
                     createReference n e ys

  where -- Función para actualizar el registro correspondiente en la tabla referenciada
        fun fk k r1 r2  = case comp k r1 r2 of
                            Eq y -> let f (TFK l) = Just $ TFK $ fk:l
                                        in Eq $ update f "fkey" y
                            y -> y



-- Borrar todas las tablas
dropAllTable :: Env -> IO()
dropAllTable e = do res <- unWrapperQuery e $ obtainTable "DataBase/system/" "Tables"
                    case res of
                     Left msgError -> put msgError
                     Right t -> do  let reg = createInfoRegister e
                                    let t' = filterT (comp3 fields0 reg) t
                                    let path  = url e
                                    b <- doesDirectoryExist path
                                    if b then deleteDirectory path
                                    else return ()
                                    createDirectory path
                                    reWrite t' tablepath
                                    succesDropAllTables (dataBase e)



-- Borrar una tabla
dropTable :: Env -> TableName -> IO ()
dropTable e n = do res <- unWrapperQuery e $ obtainTable "DataBase/system/" "Tables"
                   case res of
                     Left msgError -> put msgError
                     Right t -> do inf <- unWrapperQuery e $ loadInfoTable ["refBy","fkey"] e n
                                   case inf of
                                    Left msgError -> put msgError
                                    Right [TR ref,TFK fkey] -> -- Si existen tablas que hagan referencia a n no se puede eliminar
                                                                if fkey /= [] then imposibleDelete n [x | (x,_,_,_) <- fkey]
                                                                else dropTable' [x | (x,_) <- ref] e n t

 where
  -- segundo nivel de dropTable
  dropTable' l e n t  =
              do t' <- removeReferences e t n l
                 let reg = createInfoRegister2 e n
                 case deleteT  (comp2 fields reg) t' of
                   Nothing -> putStrLn $ errorDropTable n
                   Just t'' -> do reWrite t'' tablepath
                                  let r = url' e n
                                  deleteFile $ r ++ ".hs"
                                  deleteFile $ r ++ ".o"
                                  succesDropTable n


-- Elimina todas las referencias hechas por la tabla n
removeReferences :: Env -> AVL (HashMap String TableInfo) -> String -> [String] -> IO(AVL (HashMap String TableInfo))
removeReferences _ t _ [] = return t
removeReferences e t n (x:xs) = let reg = fromList $ zip fields [TO (name e), TB (dataBase e), TN x]
                                    t' = write (find n reg) t
                                in removeReferences e t' n xs

          -- Se elimina la tabla n de la lista de referencias de la tabla x
    where find x r1 r2 = case comp fields r1 r2 of
                        Eq _ -> Eq (change x r2)
                        other -> other
          -- modificar lista en hashmap de r2
          change x r2 = alter (change' x) "refBy" r2
          change' x (Just (TFK l)) = Just $ TFK [(a,b,c,d) | (a,b,c,d) <- l, a /= x]


-- Procesa las columnas para separar la información
collect :: [CArgs] -> TableDescript
collect [] = ([],[],[],[],[])
collect((Col n t hn):xs) = let (l1,l2,l3,k,fk) = collect xs
                          in -- Chequear si la columna admite nulos
                             if hn then (n:l1,t:l2,n:l3,k,fk)
                             else (n:l1,t:l2,l3,k,fk)
collect ((PKey s):xs) = let (l1,l2,l3,k,fk) = collect xs
                        in (l1,l2,l3,s++k,fk)
collect ((FKey xs s ys o1 o2):rs) = let (l1,l2,l3,k,fk) = collect rs
                                    in (l1,l2,l3,k,(s,zip xs ys,o1,o2):fk)


-- Mostrar todas las tablas correspondientes a la actual base de datos
showTable :: Env -> IO()
showTable e = do res <- unWrapperQuery e $  obtainTable syspath "Tables"
                 case res of
                  Left msgError -> put msgError
                  Right t -> do let fields4 = ["owner","dataBase"]
                                let reg = fromList $ zip  fields4 [TO (name e), TB (dataBase e)]
                                let t' = filterT (predic fields4  reg) t
                                printTable show3 ["tableName"] t'


   where predic fields r1 r2   = case comp fields r1 r2 of
                                Eq _ -> True
                                _ -> False
